// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// FeeRouter — splits protocol fees three ways, by fixed shares pinned at deploy.
///
/// Every protocol fee (denominated in one stable `token`, e.g. USDG) is pushed to this router and then
/// `flush()`ed. flush() fans the router's whole balance out by immutable basis-point shares:
///   - `bellBps`     -> the Bell's pot (the Seat revenue-share; the Bell reads its pot from its own balance,
///                       so a plain transfer funds it — no approval, no privileged caller),
///   - `bankrollBps` -> the bankroll (solvency reserve re-seed),
///   - the remainder -> `ops` (operating runway).
///
/// The three destinations AND the three shares are ALL immutable: no owner, no setter, no upgrade, no rescue.
/// The only thing this contract can ever do with a fee is split it in the ratio it was born with, to the three
/// addresses it was born with. There is nothing to trust between a deposited fee and its split. The value that
/// returns to the protocol (Seat holders + solvency) is `bellBps + bankrollBps`; only `ops` leaves the loop.
///
/// flush() is PERMISSIONLESS and IDEMPOTENT: anyone (a keeper, or the emitter that just deposited the fee) may
/// call it; it splits whatever balance is present; and it is always safe to call again — a zero balance is a
/// no-op, not a revert. Integer-division dust folds into the Bell's cut, so it accrues to Seat holders and the
/// entire balance always leaves in a single call — nothing is ever stranded in the router.
contract FeeRouter is ReentrancyGuard {
  using SafeERC20 for IERC20;

  uint256 public constant BPS = 10_000;

  IERC20 public immutable token; // the fee asset routed (== Bell.reward(), so the Bell is funded by transfer)
  address public immutable bell; // Seat revenue-share pot
  address public immutable bankroll; // solvency reserve re-seed
  address public immutable ops; // operating runway (the only cut that does not return to the protocol)
  uint256 public immutable bellBps; // share to the Bell pot
  uint256 public immutable bankrollBps; // share to the bankroll (ops share is the remainder to BPS)

  event Routed(uint256 total, uint256 toBell, uint256 toBankroll, uint256 toOps);

  error ZeroAddress();
  error SelfDestination();
  error BadSplit();

  constructor(
    IERC20 token_,
    address bell_,
    address bankroll_,
    address ops_,
    uint256 bellBps_,
    uint256 bankrollBps_
  ) {
    if (
      address(token_) == address(0) || bell_ == address(0) || bankroll_ == address(0) || ops_ == address(0)
    ) revert ZeroAddress();
    // A destination that is the router itself would send its cut back into the pool to be re-split on the
    // next flush, silently leaking that share to the other two sinks over time. Impossible-by-construction
    // beats deploy discipline (the SeatReserve principle), and the router is immutable — so reject it here.
    if (bell_ == address(this) || bankroll_ == address(this) || ops_ == address(this)) revert SelfDestination();
    // Every share must be strictly positive and the three must sum to exactly BPS: no fee is ever left
    // unassigned, and no destination is a dead 0% (which would be a silently misconfigured split). The ops
    // share is derived as BPS - bellBps - bankrollBps, so requiring bellBps + bankrollBps < BPS with both
    // non-zero forces all three into (0, BPS). The per-share `>= BPS` clauses bound each input below BPS
    // FIRST, so `bellBps_ + bankrollBps_` can never overflow-wrap to a small value that sneaks past the sum
    // check (impossible-by-construction, matching the SeatReserve principle — the config is immutable).
    if (
      bellBps_ == 0 || bankrollBps_ == 0 || bellBps_ >= BPS || bankrollBps_ >= BPS
        || bellBps_ + bankrollBps_ >= BPS
    ) revert BadSplit();
    token = token_;
    bell = bell_;
    bankroll = bankroll_;
    ops = ops_;
    bellBps = bellBps_;
    bankrollBps = bankrollBps_;
  }

  /// The ops share, derived so the three shares always sum to exactly BPS.
  function opsBps() external view returns (uint256) {
    return BPS - bellBps - bankrollBps;
  }

  /// Split the router's entire balance to the three destinations by the immutable shares. Permissionless and
  /// idempotent — safe to call anytime; a zero balance is a no-op. Rounding dust folds into the Bell's cut
  /// (favouring Seat holders), so the whole balance always leaves in one call and nothing is stranded.
  function flush() external nonReentrant returns (uint256 toBell, uint256 toBankroll, uint256 toOps) {
    uint256 bal = token.balanceOf(address(this));
    if (bal == 0) return (0, 0, 0);

    toBankroll = (bal * bankrollBps) / BPS;
    toOps = (bal * (BPS - bellBps - bankrollBps)) / BPS;
    toBell = bal - toBankroll - toOps; // remainder (incl. rounding dust) -> the revenue-share

    token.safeTransfer(bell, toBell);
    token.safeTransfer(bankroll, toBankroll);
    token.safeTransfer(ops, toOps);
    emit Routed(bal, toBell, toBankroll, toOps);
  }
}
