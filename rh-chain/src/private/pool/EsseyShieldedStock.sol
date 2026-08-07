// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleTreeWithHistory} from "./MerkleTreeWithHistory.sol";
import {IPoolVerifier, IEsseyPoolGate} from "./EsseyShieldedPool.sol";

/// Essey Private — SHIELDED STOCK. A shielded pool for a tokenized-stock token (AAPL/NVDA) on Robinhood
/// Chain. The zk core (Merkle tree, nullifiers, join-split proof, verifier, hasher) is IDENTICAL to
/// EsseyShieldedPool; only the token-edge accounting differs, to survive the ONE hazard a vanilla Nova pool
/// does not: the tokenized-stock issuer holds an arbitrary-address `adminBurn(from, amount)` (a Robinhood
/// Stock Token surface, modeled by MockStock and defended against by CollateralReconciler on the lending
/// side). A vanilla shielded pool assumes its ERC-20 backing is inviolable; a burnable backing breaks that.
///
/// THE FAILURE MODE (characterized by the harness): if the issuer burns the pool's own backing, the pool
/// holds LESS than the sum of outstanding note values. A vanilla pool pays each withdrawal in full, first-
/// come-first-served, so the earliest exiters are made whole and the last ones hit ERC20InsufficientBalance
/// and are FROZEN OUT entirely — a bank run, and the residual backing is stranded.
///
/// THE MITIGATION (this contract): a PRO-RATA HAIRCUT. The pool tracks `totalShielded` (the public running
/// sum of net deposits — the same aggregate a vanilla pool already exposes via balanceOf, so no new leak).
/// A withdrawal pays `noteValue * balanceOf / totalShielded` — i.e. scaled by the solvency ratio. The ratio
/// `balanceOf / totalShielded` is PRESERVED under haircut withdrawals up to integer rounding: paying value*r
/// and decrementing totalShielded by value keeps it fixed, and flooring retains sub-unit dust so the ratio is
/// monotonically NON-DECREASING (it weakly improves for remaining holders, never drops). So every holder takes
/// the same proportional loss regardless of exit order — a later exiter is never disadvantaged, only dust-scale
/// advantaged. When solvent (balanceOf >= totalShielded) the haircut is the identity — behaviour is byte-for-
/// byte the base pool. Two further guards close the design:
///   - DEPOSIT SOLVENCY GATE: a deposit is admitted only while the pool is fully backed. Once a burn impairs
///     it, deposits close (withdraw-only), so a new depositor can never be diluted into subsidizing the loss.
///     There is deliberately NO admin re-open: a spurious dust-impairment (issuer burns 1 wei) recovers only
///     when backing is restored (anyone can donate the shortfall) — safety (never subsidize a burn) over
///     liveness (deposits may pause). Existing holders can always still exit at the live ratio.
///   - DEPOSIT PAUSE: an operational control (like any protocol feature), NEVER applied to withdrawals — you
///     can always exit what you shielded. It is not a compliance kill-switch.
///
/// STATED ASSUMPTION (verify against the live token before mainnet): the pool treats ANY drop in its raw
/// `balanceOf` below `totalShielded` as an adminBurn loss. This is correct ONLY if raw balance is reduced
/// solely by adminBurn, never by a legitimate corporate action. The tokenized-stock `uiMultiplier` (ERC-8056
/// scaled-UI) scales the DISPLAY, not raw balances (valuation = raw * uiMultiplier / 1e18, per
/// CollateralReconciler / EsseyMarkets), so a normal split/dividend moves only the multiplier and leaves this
/// pool's raw-vs-raw solvency math untouched — it is uiMultiplier-agnostic, and display scaling is a frontend
/// concern. If a corporate action were ever implemented by burning raw tokens instead, this pool would
/// misread it as impairment; the Robinhood-token model says that does not happen, but it is the assumption.
///
/// SCOPE: 2-input join-split only (deposit / withdraw / 2->2 transfer), matching the base pool.
contract EsseyShieldedStock is MerkleTreeWithHistory, ReentrancyGuard {
  using SafeERC20 for IERC20;

  int256 public constant MAX_EXT_AMOUNT = 2 ** 248;
  uint256 public constant MAX_FEE = 2 ** 248;

  IPoolVerifier public immutable verifier2;
  IERC20 public immutable token; // the tokenized-stock token (AAPL/NVDA)
  IEsseyPoolGate public immutable gate;
  address public admin;

  uint256 public maximumDepositAmount;
  uint256 public totalShielded; // running sum of net deposits = the pool's EXPECTED raw backing
  bool public depositsPaused; // operational control; NEVER gates withdrawals
  mapping(bytes32 => bool) public nullifierHashes;

  struct ExtData {
    address recipient;
    int256 extAmount;
    address relayer;
    uint256 fee;
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
  event Haircut(uint256 balance, uint256 totalShielded); // emitted when a withdrawal is paid below par
  event DepositsPaused(bool paused);

  error NotAdmin();
  error DepositNotApproved();

  modifier onlyAdmin() {
    if (msg.sender != admin) revert NotAdmin();
    _;
  }

  constructor(
    IPoolVerifier _verifier2,
    uint32 _levels,
    address _hasher,
    IERC20 _token,
    IEsseyPoolGate _gate,
    address _admin,
    uint256 _maximumDepositAmount
  ) MerkleTreeWithHistory(_levels, _hasher) {
    verifier2 = _verifier2;
    token = _token;
    gate = _gate;
    admin = _admin;
    maximumDepositAmount = _maximumDepositAmount;
  }

  /// Deposit / withdraw / transfer. A deposit (extAmount > 0) must be approved by the front door, must not be
  /// paused, and is admitted ONLY while the pool is fully backed (so a new depositor can never be diluted into
  /// covering a prior burn). A withdrawal (extAmount < 0) pays the recipient their pro-rata share; a pure
  /// transfer (extAmount == 0) just rewrites notes. All value accounting is enforced inside the proof.
  function transact(Proof memory _args, ExtData memory _extData) public {
    if (_extData.extAmount > 0) {
      if (depositsPaused) revert DepositNotApproved();
      if (!gate.isApproved(msg.sender)) revert DepositNotApproved();
      require(uint256(_extData.extAmount) <= maximumDepositAmount, "amount is larger than maximumDepositAmount");
      // Solvency gate: refuse new deposits into an impaired pool (backing < outstanding). Once the issuer
      // burns the pool's backing this fails forever -> the pool becomes withdraw-only, and existing holders
      // exit pro-rata without a fresh depositor unknowingly subsidizing the shortfall.
      require(token.balanceOf(address(this)) >= totalShielded, "pool impaired - deposits closed");
      token.safeTransferFrom(msg.sender, address(this), uint256(_extData.extAmount));
      totalShielded += uint256(_extData.extAmount);
    }
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

  /// The solvency-scaled payout for a claim of `_amount` note-value, given the pool's live backing. Pure so
  /// the harness can prove socialization is order-independent, and the frontend can quote a haircut.
  function quoteHaircut(uint256 _amount, uint256 _balance, uint256 _total) public pure returns (uint256) {
    if (_total == 0) return _amount; // no outstanding notes -> nothing to dilute against
    uint256 pay = (_amount * _balance) / _total;
    return pay > _amount ? _amount : pay; // never pay above par (pool may hold donated excess)
  }

  /// What a note of `_amount` would redeem for right now (par when solvent, haircut when impaired).
  function previewWithdrawable(uint256 _amount) external view returns (uint256) {
    return quoteHaircut(_amount, token.balanceOf(address(this)), totalShielded);
  }

  /// True once the issuer has burned backing below the outstanding notes.
  function isImpaired() external view returns (bool) {
    return token.balanceOf(address(this)) < totalShielded;
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

    // Pay the recipient and relayer their PRO-RATA share of the note value. `bal` and `total` are snapshotted
    // once so both claimants scale by the same solvency ratio; `owed` (the full note value leaving the shielded
    // set) is decremented from totalShielded, which keeps balanceOf/totalShielded fixed up to rounding (dust is
    // retained by the pool, so the ratio only weakly improves) -> order-independent losses. When solvent
    // (bal >= total) quoteHaircut is the identity, so this is exactly the base pool.
    uint256 bal = token.balanceOf(address(this));
    uint256 total = totalShielded;
    uint256 owed;

    if (_extData.extAmount < 0) {
      require(_extData.recipient != address(0), "Can't withdraw to zero address");
      uint256 amt = uint256(-_extData.extAmount);
      owed += amt;
      uint256 pay = quoteHaircut(amt, bal, total);
      if (pay < amt) emit Haircut(bal, total);
      token.safeTransfer(_extData.recipient, pay);
    }
    if (_extData.fee > 0) {
      owed += _extData.fee;
      token.safeTransfer(_extData.relayer, quoteHaircut(_extData.fee, bal, total));
    }
    if (owed > 0) totalShielded = total - owed;

    _insert(_args.outputCommitments[0], _args.outputCommitments[1]);
    emit NewCommitment(_args.outputCommitments[0], nextIndex - 2, _extData.encryptedOutput1);
    emit NewCommitment(_args.outputCommitments[1], nextIndex - 1, _extData.encryptedOutput2);
    emit NewNullifier(_args.inputNullifiers[0]);
    emit NewNullifier(_args.inputNullifiers[1]);
  }

  function configureLimits(uint256 _maximumDepositAmount) external onlyAdmin {
    maximumDepositAmount = _maximumDepositAmount;
  }

  /// Operational pause on NEW deposits only. Withdrawals and transfers are never gated.
  function setDepositsPaused(bool _paused) external onlyAdmin {
    depositsPaused = _paused;
    emit DepositsPaused(_paused);
  }

  function transferAdmin(address _admin) external onlyAdmin {
    require(_admin != address(0), "zero admin");
    admin = _admin;
  }
}
