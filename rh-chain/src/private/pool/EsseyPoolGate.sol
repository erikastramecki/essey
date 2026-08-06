// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Essey Private — the shielded pool's FRONT DOOR (the Veil architecture): all compliance lives here, in a
/// separate operator-controlled contract, so the zk pool stays a clean, unmodified Nova core. The pool asks
/// `isApproved(depositor)` before letting funds IN; withdrawals are never gated (you can always exit what
/// you shielded). Screen-then-admit: the operator (an off-chain ASP / KYT process) approves addresses that
/// pass origin-of-funds checks; unapproved deposits revert.
///
/// Phase 1 is a straight allow-list — the minimal, auditable version of the operator association-set. The
/// credential fast-paths (onchain-verified identity attestations) and the async KYT queue-with-refund are
/// deliberately deferred; they layer on top of this same `isApproved` interface without touching the pool.
///
/// This contract holds NO funds and cannot move money. Its only power is admitting/denying deposit access.
contract EsseyPoolGate {
  address public operator; // the ASP role — curates the approved set
  bool public openMode; // if true, everyone is approved (testnet convenience; MUST be false in production)

  mapping(address => bool) public approved;

  event OperatorTransferred(address indexed from, address indexed to);
  event ApprovalSet(address indexed account, bool approved);
  event OpenModeSet(bool open);

  error NotOperator();
  error ZeroOperator();

  modifier onlyOperator() {
    if (msg.sender != operator) revert NotOperator();
    _;
  }

  constructor(address _operator, bool _openMode) {
    if (_operator == address(0)) revert ZeroOperator();
    operator = _operator;
    openMode = _openMode;
    emit OperatorTransferred(address(0), _operator);
    emit OpenModeSet(_openMode);
  }

  /// The pool calls this on every deposit. Approved (or open mode) → deposit proceeds; else the pool reverts.
  function isApproved(address account) external view returns (bool) {
    return openMode || approved[account];
  }

  /// Operator admits or revokes a single depositor (the association-set edit).
  function setApproved(address account, bool ok) external onlyOperator {
    approved[account] = ok;
    emit ApprovalSet(account, ok);
  }

  /// Batch admit/revoke — one operator tx to update many entries.
  function setApprovedBatch(address[] calldata accounts, bool ok) external onlyOperator {
    for (uint256 i = 0; i < accounts.length; i++) {
      approved[accounts[i]] = ok;
      emit ApprovalSet(accounts[i], ok);
    }
  }

  /// Testnet convenience: approve everyone. Production deployments set this false and gate on the allow-list.
  function setOpenMode(bool open) external onlyOperator {
    openMode = open;
    emit OpenModeSet(open);
  }

  function transferOperator(address to) external onlyOperator {
    if (to == address(0)) revert ZeroOperator();
    emit OperatorTransferred(operator, to);
    operator = to;
  }
}
