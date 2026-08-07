// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleTreeWithHistory} from "./MerkleTreeWithHistory.sol";
import {IPoolVerifier, IEsseyPoolGate} from "./EsseyShieldedPool.sol";

/// The lending pool this shields — an ERC-4626 vault (EsseyPool): supply USDG for `aUSDG` shares that
/// appreciate as interest accrues. We only need this subset.
interface ILendingPool {
  function deposit(uint256 assets, address receiver) external returns (uint256 shares);
  function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
  function previewDeposit(uint256 assets) external view returns (uint256);
  function convertToAssets(uint256 shares) external view returns (uint256);
}

/// Essey Private — SHIELDED LENDING SUPPLY. A shielded pool whose notes are denominated in aUSDG SHARES of
/// the lending pool, so a supplier's position — and the yield it earns — are private. The zk core (Merkle
/// tree, nullifiers, join-split proof, verifier, hasher) is IDENTICAL to EsseyShieldedPool; a "value" is just
/// a field element, so the same circuit works for shares. The ONLY difference is the token edges:
///
///   supply()  : pull USDG from the user, deposit it into the lending pool, and shield the SHARES received.
///   withdraw  : redeem the note's shares from the lending pool back to USDG for the recipient.
///   transfer  : move share-notes between users in-pool (unchanged).
///
/// Yield is private "for free": a note's SHARE count is fixed, but the shares appreciate, so its USDG value
/// grows without any on-chain event tied to the supplier. The extDataHash still binds recipient/relayer/fee,
/// so relayed private withdrawals work exactly as in the base pool.
contract EsseyShieldedSupply is MerkleTreeWithHistory, ReentrancyGuard {
  using SafeERC20 for IERC20;

  int256 public constant MAX_EXT_AMOUNT = 2 ** 248;
  uint256 public constant MAX_FEE = 2 ** 248;

  IPoolVerifier public immutable verifier2;
  IERC20 public immutable usdg; // the underlying asset users deposit/receive
  ILendingPool public immutable lendingPool; // the ERC-4626 vault; the pool holds its shares
  IEsseyPoolGate public immutable gate;
  address public admin;

  uint256 public maximumSupplyShares; // per-supply cap, in SHARES (0 = no cap)
  mapping(bytes32 => bool) public nullifierHashes;

  struct ExtData {
    address recipient;
    int256 extAmount; // in SHARES (positive = supply, negative = withdraw, zero = transfer)
    address relayer;
    uint256 fee; // relayer fee, in SHARES
    bytes encryptedOutput1;
    bytes encryptedOutput2;
  }

  struct Proof {
    uint256[2] a;
    uint256[2][2] b;
    uint256[2] c;
    bytes32 root;
    bytes32[2] inputNullifiers;
    bytes32[2] outputCommitments;
    uint256 publicAmount;
    bytes32 extDataHash;
  }

  struct Account {
    address owner;
    bytes publicKey;
  }

  event NewCommitment(bytes32 commitment, uint256 index, bytes encryptedOutput);
  event NewNullifier(bytes32 nullifier);
  event PublicKey(address indexed owner, bytes key);

  error NotAdmin();
  error SupplyNotApproved();

  modifier onlyAdmin() {
    if (msg.sender != admin) revert NotAdmin();
    _;
  }

  constructor(
    IPoolVerifier _verifier2,
    uint32 _levels,
    address _hasher,
    IERC20 _usdg,
    ILendingPool _lendingPool,
    IEsseyPoolGate _gate,
    address _admin,
    uint256 _maximumSupplyShares
  ) MerkleTreeWithHistory(_levels, _hasher) {
    verifier2 = _verifier2;
    usdg = _usdg;
    lendingPool = _lendingPool;
    gate = _gate;
    admin = _admin;
    maximumSupplyShares = _maximumSupplyShares;
  }

  /// SUPPLY USDG privately. Pull `usdgAmount` from the caller, deposit it into the lending pool, and shield
  /// the shares. The proof's extAmount is the SHARE amount — the caller computes it via previewDeposit and
  /// the deposit must yield EXACTLY that many shares (ERC-4626 deposit returns previewDeposit(assets)), so a
  /// rate move between proving and submitting reverts cleanly (retry). Gated by the front door.
  function supply(uint256 usdgAmount, Proof memory _args, ExtData memory _extData) public {
    if (!gate.isApproved(msg.sender)) revert SupplyNotApproved();
    require(_extData.extAmount > 0, "supply must add value");
    uint256 shares = uint256(_extData.extAmount);
    if (maximumSupplyShares != 0) require(shares <= maximumSupplyShares, "over supply cap");

    usdg.safeTransferFrom(msg.sender, address(this), usdgAmount);
    usdg.forceApprove(address(lendingPool), usdgAmount);
    uint256 got = lendingPool.deposit(usdgAmount, address(this));
    require(got == shares, "share/value mismatch (rate moved) - retry");

    _transact(_args, _extData);
  }

  /// WITHDRAW (redeem the note's shares to USDG for the recipient) or TRANSFER in-pool (extAmount == 0). No
  /// USDG is pulled; the recipient / relayer are paid by redeeming shares from the lending pool.
  function transact(Proof memory _args, ExtData memory _extData) public {
    require(_extData.extAmount <= 0, "use supply() to add value");
    _transact(_args, _extData);
  }

  function register(Account memory _account) public {
    require(_account.owner == msg.sender, "only owner can be registered");
    emit PublicKey(_account.owner, _account.publicKey);
  }

  function registerAndTransact(Account memory _account, Proof memory _args, ExtData memory _extData) public {
    register(_account);
    transact(_args, _extData);
  }

  function calculatePublicAmount(int256 _extAmount, uint256 _fee) public pure returns (uint256) {
    require(_fee < MAX_FEE, "Invalid fee");
    require(_extAmount > -MAX_EXT_AMOUNT && _extAmount < MAX_EXT_AMOUNT, "Invalid ext amount");
    int256 publicAmount = _extAmount - int256(_fee);
    return (publicAmount >= 0) ? uint256(publicAmount) : FIELD_SIZE - uint256(-publicAmount);
  }

  function isSpent(bytes32 _nullifierHash) public view returns (bool) {
    return nullifierHashes[_nullifierHash];
  }

  /// USDG value of `shares` right now (for showing a private balance in USDG terms — off-chain use).
  function sharesToUsdg(uint256 shares) external view returns (uint256) {
    return lendingPool.convertToAssets(shares);
  }

  function verifyProof(Proof memory _args) public view returns (bool) {
    return verifier2.verifyProof(
      _args.a,
      _args.b,
      _args.c,
      [
        uint256(_args.root),
        _args.publicAmount,
        uint256(_args.extDataHash),
        uint256(_args.inputNullifiers[0]),
        uint256(_args.inputNullifiers[1]),
        uint256(_args.outputCommitments[0]),
        uint256(_args.outputCommitments[1])
      ]
    );
  }

  function _transact(Proof memory _args, ExtData memory _extData) internal nonReentrant {
    require(isKnownRoot(_args.root), "Invalid merkle root");
    require(!isSpent(_args.inputNullifiers[0]), "Input 0 is already spent");
    require(!isSpent(_args.inputNullifiers[1]), "Input 1 is already spent");
    require(
      uint256(_args.extDataHash) == uint256(keccak256(abi.encode(_extData))) % FIELD_SIZE,
      "Incorrect external data hash"
    );
    require(_args.publicAmount == calculatePublicAmount(_extData.extAmount, _extData.fee), "Invalid public amount");
    require(verifyProof(_args), "Invalid transaction proof");

    nullifierHashes[_args.inputNullifiers[0]] = true;
    nullifierHashes[_args.inputNullifiers[1]] = true;

    // Withdraw: redeem the note's shares from the lending pool back to USDG for the recipient (incl. yield).
    if (_extData.extAmount < 0) {
      require(_extData.recipient != address(0), "Can't withdraw to zero address");
      lendingPool.redeem(uint256(-_extData.extAmount), _extData.recipient, address(this));
    }
    // Relayer fee, also paid by redeeming `fee` shares to USDG.
    if (_extData.fee > 0) {
      lendingPool.redeem(_extData.fee, _extData.relayer, address(this));
    }

    _insert(_args.outputCommitments[0], _args.outputCommitments[1]);
    emit NewCommitment(_args.outputCommitments[0], nextIndex - 2, _extData.encryptedOutput1);
    emit NewCommitment(_args.outputCommitments[1], nextIndex - 1, _extData.encryptedOutput2);
    emit NewNullifier(_args.inputNullifiers[0]);
    emit NewNullifier(_args.inputNullifiers[1]);
  }

  function configureLimits(uint256 _maximumSupplyShares) external onlyAdmin {
    maximumSupplyShares = _maximumSupplyShares;
  }

  function transferAdmin(address _admin) external onlyAdmin {
    require(_admin != address(0), "zero admin");
    admin = _admin;
  }
}
