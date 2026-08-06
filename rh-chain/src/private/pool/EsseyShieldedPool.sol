// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleTreeWithHistory} from "./MerkleTreeWithHistory.sol";

/// The Groth16 verifier for the 2-input join-split (snarkjs-generated). 7 public signals, in order:
/// [root, publicAmount, extDataHash, inputNullifier0, inputNullifier1, outputCommitment0, outputCommitment1].
interface IPoolVerifier {
  function verifyProof(
    uint256[2] calldata a,
    uint256[2][2] calldata b,
    uint256[2] calldata c,
    uint256[7] calldata input
  ) external view returns (bool);
}

/// The operator front door — deposits are admitted only for approved addresses. See EsseyPoolGate.
interface IEsseyPoolGate {
  function isApproved(address account) external view returns (bool);
}

/// Essey Private — a shielded USDG pool. Ported from Tornado Nova (MIT) to Solidity 0.8.28 and stripped of
/// the Gnosis L1<->L2 bridge machinery (OmniBridge / CrossChainGuard / L1 unwrapper) down to a single-chain
/// ERC-20 pool for Robinhood Chain. It hides AMOUNTS: deposits, in-pool transfers, and withdrawals move
/// UTXO notes whose values are committed inside the zk proof, not exposed on-chain.
///
/// The ONLY change to Nova's core is the front-door hook: a deposit calls `gate.isApproved(msg.sender)`
/// first, so the operator's compliance screening (the association set) admits funds IN. Withdrawals are
/// never gated — you can always exit what you shielded. Everything else — the Merkle tree, nullifier set,
/// join-split verification, amount invariant — is Nova's, unmodified in spirit.
///
/// SCOPE: 2-input join-split only (deposit / withdraw / 2->2 transfer). The 16-input circuit is a later add.
contract EsseyShieldedPool is MerkleTreeWithHistory, ReentrancyGuard {
  using SafeERC20 for IERC20;

  int256 public constant MAX_EXT_AMOUNT = 2 ** 248;
  uint256 public constant MAX_FEE = 2 ** 248;

  IPoolVerifier public immutable verifier2;
  IERC20 public immutable token;
  IEsseyPoolGate public immutable gate;
  address public admin;

  uint256 public lastBalance;
  uint256 public maximumDepositAmount;
  mapping(bytes32 => bool) public nullifierHashes;

  struct ExtData {
    address recipient;
    int256 extAmount;
    address relayer;
    uint256 fee;
    bytes encryptedOutput1;
    bytes encryptedOutput2;
  }

  /// A Groth16 proof (a/b/c) plus the public inputs the circuit exposes.
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

  /// Deposit / withdraw / transfer. A deposit (extAmount > 0) must be approved by the front door and pulls
  /// tokens in; a withdrawal (extAmount < 0) pays the recipient; a pure transfer (extAmount == 0) just
  /// rewrites notes. All value accounting is enforced inside the proof.
  function transact(Proof memory _args, ExtData memory _extData) public {
    if (_extData.extAmount > 0) {
      if (!gate.isApproved(msg.sender)) revert DepositNotApproved();
      require(uint256(_extData.extAmount) <= maximumDepositAmount, "amount is larger than maximumDepositAmount");
      token.safeTransferFrom(msg.sender, address(this), uint256(_extData.extAmount));
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

    if (_extData.extAmount < 0) {
      require(_extData.recipient != address(0), "Can't withdraw to zero address");
      token.safeTransfer(_extData.recipient, uint256(-_extData.extAmount));
    }
    if (_extData.fee > 0) {
      token.safeTransfer(_extData.relayer, _extData.fee);
    }

    lastBalance = token.balanceOf(address(this));
    _insert(_args.outputCommitments[0], _args.outputCommitments[1]);
    emit NewCommitment(_args.outputCommitments[0], nextIndex - 2, _extData.encryptedOutput1);
    emit NewCommitment(_args.outputCommitments[1], nextIndex - 1, _extData.encryptedOutput2);
    emit NewNullifier(_args.inputNullifiers[0]);
    emit NewNullifier(_args.inputNullifiers[1]);
  }

  function configureLimits(uint256 _maximumDepositAmount) external onlyAdmin {
    maximumDepositAmount = _maximumDepositAmount;
  }

  function transferAdmin(address _admin) external onlyAdmin {
    require(_admin != address(0), "zero admin");
    admin = _admin;
  }
}
