// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Guarded — the freeze-only guardian (founder-approved 2026-08-11). One narrow power, held by the
/// admin multisig: STOP NEW ACTIVITY in an incident. Nothing more.
///
/// The trust math that makes this safe to add to an otherwise-adminless system:
///   - `freeze()` gates only the paths where NEW liabilities originate (a new loan, a new trade, a new
///     spin). Every EXIT — repay, claim, redeem, withdraw, liquidation settlement — deliberately never
///     checks the flag, so the guardian can close the front door but structurally cannot trap a wei.
///   - Freezing is INSTANT (incident response cannot wait a timelock); so is unfreezing — the worst a
///     rogue guardian can ever do is pause new business, a bounded griefing ceiling, not theft.
///   - `renounceGuardian()` is the one-way graduation: once the system is battle-tested, the multisig
///     renounces and the contract becomes permanently unfreezable — fully immutable, forever. Renounce
///     requires the contract be UNFROZEN, so a dying guardian cannot freeze-then-renounce and brick
///     new activity permanently.
///
/// Deliberately NOT applied to the DonReserve (the floor stays absolutely adminless — redemption is
/// the canonical always-open exit that makes freezing a market venue acceptable) nor the Bell.
abstract contract Guarded {
    address public guardian; // the admin multisig; address(0) after renounce = unfreezable forever
    bool public frozen;

    event Frozen(address indexed by);
    event Unfrozen(address indexed by);
    event GuardianRenounced();

    error NotGuardian();
    error IsFrozen();
    error NotWhileFrozen();

    modifier whenNotFrozen() {
        if (frozen) revert IsFrozen();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(address guardian_) {
        guardian = guardian_; // address(0) allowed = deployed already-immutable (no guardian ever)
    }

    /// Stop new activity. Instant, guardian-only. Exits are untouched by construction.
    function freeze() external onlyGuardian {
        frozen = true;
        emit Frozen(msg.sender);
    }

    /// Resume new activity. Instant, guardian-only.
    function unfreeze() external onlyGuardian {
        frozen = false;
        emit Unfrozen(msg.sender);
    }

    /// The one-way graduation to full immutability. Only from a running (unfrozen) state.
    function renounceGuardian() external onlyGuardian {
        if (frozen) revert NotWhileFrozen();
        guardian = address(0);
        emit GuardianRenounced();
    }
}
