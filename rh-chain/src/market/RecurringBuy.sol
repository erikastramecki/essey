// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// The stock converter this settles through. `convert` is permissionless, pulls `amountIn` base from the
/// caller, enforces an oracle-fair floor + US-session gate + stale-feed discipline itself, and delivers the
/// stock straight to `recipient`. We only need this subset.
interface IStockConverter {
  function convert(uint256 amountIn, address targetToken, address recipient) external returns (uint256 amountOut);
  function isSupported(address token) external view returns (bool);
}

/// RecurringBuy — "Auto-stack into stock": a non-custodial dollar-cost-average.
///
/// A user creates a schedule (buy `amountPerFill` USDG of a stock every `everySec`, up to `totalFills`). Their
/// funds STAY IN THEIR WALLET — nothing is escrowed. Each due fill pulls exactly one fill's USDG via a standard
/// allowance and settles it through the StockConverter, which delivers the stock straight to the owner at an
/// oracle-fair price (or reverts). Execution is PERMISSIONLESS: anyone (a keeper, or the user) may call
/// `executeFill` on a due schedule. That is safe by the converter's design — an executor controls only WHETHER
/// a fill lands, never HOW WELL (the floor is enforced in `convert`), and only WHEN it's due. Off-market or on a
/// stale feed, `convert` reverts, so the whole fill reverts and simply retries at the next valid window.
///
/// The grid is SKIP-NOT-BACKFILL: a successful fill advances `nextDue` past every elapsed period to the next
/// future slot, so a down keeper costs missed slices, never a lump catch-up. Cancel any time (or just revoke the
/// USDG allowance — the schedule then can't pull anything). Minimal & immutable: no owner, no admin, no upgrade.
contract RecurringBuy is ReentrancyGuard {
  using SafeERC20 for IERC20;

  IERC20 public immutable usdg; // the base asset each fill spends (must match the converter's base)
  IStockConverter public immutable converter;

  uint64 public constant MIN_INTERVAL = 60; // 60 seconds
  uint64 public constant MAX_INTERVAL = 90 days;
  uint32 public constant MAX_FILLS = 1000;

  struct Schedule {
    address owner; // funds are pulled from here; stock is delivered here
    address stock; // target stock token (must be converter.isSupported)
    uint128 amountPerFill; // USDG spent per fill
    uint64 everySec; // seconds between fills
    uint32 totalFills; // total planned fills
    uint32 filled; // fills completed
    uint64 nextDue; // earliest timestamp of the next fill (grid anchor)
    bool cancelled;
  }

  mapping(uint256 => Schedule) public schedules;
  uint256 public nextId;

  event Created(uint256 indexed id, address indexed owner, address indexed stock, uint128 amountPerFill, uint64 everySec, uint32 totalFills);
  event Filled(uint256 indexed id, uint32 fillNumber, uint256 amountIn, uint256 amountOut, uint64 nextDue);
  event Completed(uint256 indexed id);
  event Cancelled(uint256 indexed id);

  error NotOwner();
  error BadParams();
  error StockNotSupported();
  error NotActive();
  error NotDue();

  constructor(IERC20 _usdg, IStockConverter _converter) {
    require(address(_usdg) != address(0) && address(_converter) != address(0), "zero addr");
    usdg = _usdg;
    converter = _converter;
  }

  /// Create a recurring buy. Funds are NOT taken now — the caller keeps them and grants a USDG allowance to this
  /// contract; each fill pulls exactly `amountPerFill`. First fill is eligible immediately.
  function create(address stock, uint128 amountPerFill, uint64 everySec, uint32 totalFills)
    external
    returns (uint256 id)
  {
    if (amountPerFill == 0 || totalFills == 0 || totalFills > MAX_FILLS) revert BadParams();
    if (everySec < MIN_INTERVAL || everySec > MAX_INTERVAL) revert BadParams();
    if (!converter.isSupported(stock)) revert StockNotSupported();

    id = ++nextId;
    schedules[id] = Schedule({
      owner: msg.sender,
      stock: stock,
      amountPerFill: amountPerFill,
      everySec: everySec,
      totalFills: totalFills,
      filled: 0,
      nextDue: uint64(block.timestamp),
      cancelled: false
    });
    emit Created(id, msg.sender, stock, amountPerFill, everySec, totalFills);
  }

  /// Execute one due fill. Permissionless — a keeper or the owner may call it. Advances the grid (skip-not-
  /// backfill), pulls one fill's USDG from the owner, and settles it through the converter to the owner. If the
  /// converter reverts (closed session, stale feed, floor not met), the WHOLE call reverts and no state changes —
  /// the fill simply retries at the next attempt. Effects (grid advance) precede the external calls (CEI).
  function executeFill(uint256 id) external nonReentrant {
    Schedule storage s = schedules[id];
    if (s.owner == address(0) || s.cancelled || s.filled >= s.totalFills) revert NotActive();
    if (block.timestamp < s.nextDue) revert NotDue();

    // Advance the grid to the next strictly-future slot on the ORIGINAL phase (missed periods are skipped, never
    // back-filled). Do this BEFORE the external calls so a reverting convert rolls it all back atomically.
    uint64 due = s.nextDue;
    uint64 elapsed = uint64(block.timestamp) - due;
    s.nextDue = due + (elapsed / s.everySec + 1) * s.everySec;
    uint32 n = s.filled + 1;
    s.filled = n;

    uint128 amt = s.amountPerFill;
    // Pull exactly one fill from the owner (funds otherwise stay in their wallet) and settle it to the owner. The
    // converter enforces the oracle floor + session gate; it delivers the stock directly to `s.owner`.
    usdg.safeTransferFrom(s.owner, address(this), amt);
    usdg.forceApprove(address(converter), amt);
    uint256 out = converter.convert(amt, s.stock, s.owner);
    usdg.forceApprove(address(converter), 0);

    emit Filled(id, n, amt, out, s.nextDue);
    if (n == s.totalFills) emit Completed(id);
  }

  /// Cancel a schedule (owner only). Revoking the USDG allowance also neutralizes it — nothing can be pulled.
  function cancel(uint256 id) external {
    Schedule storage s = schedules[id];
    if (s.owner != msg.sender) revert NotOwner();
    s.cancelled = true;
    emit Cancelled(id);
  }

  /// Is this schedule executable right now? (active, not done, and past its next-due time.)
  function dueNow(uint256 id) external view returns (bool) {
    Schedule memory s = schedules[id];
    return s.owner != address(0) && !s.cancelled && s.filled < s.totalFills && block.timestamp >= s.nextDue;
  }
}
