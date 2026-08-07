// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// The Seat's fixed cap. The reserve reads it directly so `backedSupply` is pinned to the true maximum on-chain.
interface ISeatSupply {
  function maxSupply() external view returns (uint256);
}

/// SeatReserve — a hard, stable, rising price FLOOR for Seats.
///
/// Every Seat is backed by a share of a USDG reserve. A Seat's floor is `reserve / backedSupply` — the
/// reserve split evenly across the Seats it backs. Anyone may `fund()` the reserve (raising the floor for
/// everyone); a Seat's owner may `redeem()` it to lock the Seat here and claim its floor share in USDG. Because
/// redemption is always open at the floor, a Seat can never trade below it (arbitrage), so holders have a hard
/// downside in STABLE value — an upgrade over the Exchange's fixed-$ESSEY sell-back, whose value tracks a
/// volatile access token. The floor RISES as the reserve is funded (e.g. from protocol proceeds).
///
/// The floor is PRO-RATA and provably fair: paying a redeemer `reserve/backedSupply` and decrementing both the
/// reserve (by that payout) and `backedSupply` (by one) leaves `reserve/backedSupply` unchanged — the same
/// invariance the shielded-stock haircut relies on. So redemption order never disadvantages anyone; integer
/// rounding retains sub-unit dust in the reserve, so the floor is monotonically NON-DECREASING.
///
/// DELIBERATELY MINIMAL & IMMUTABLE: no owner, no admin, no upgrade, no setter on `backedSupply` (which would
/// be a rug — lowering it inflates the floor and drains the reserve). `backedSupply` is set once at deployment
/// and only ever decrements via `redeem`. There is nothing to trust between the deposit and the floor.
contract SeatReserve is ReentrancyGuard {
  using SafeERC20 for IERC20;

  IERC20 public immutable usdg; // the reserve asset (a Seat's floor is paid in this)
  IERC721 public immutable seat; // the Seat NFT this backs
  uint256 public backedSupply; // Seats still backed by the reserve (init = the Seat supply; -1 per redeem)

  event Funded(address indexed from, uint256 amount, uint256 newFloorPerSeat);
  event Redeemed(address indexed owner, uint256 indexed seatId, uint256 paid);

  error NoFloor();
  error NotSeatOwner();
  error NothingBacked();

  constructor(IERC20 _usdg, IERC721 _seat) {
    require(address(_usdg) != address(0) && address(_seat) != address(0), "zero addr");
    // Pin backedSupply to the Seat's on-chain cap, NOT a passed-in value. Backing the full maxSupply is the
    // only theft-proof choice — since Seats can never exceed maxSupply, existing Seats can never exceed
    // backedSupply, so an early redeemer can never drain a share funded for a Seat that still can't redeem. This
    // makes the guarantee safe-by-construction rather than dependent on deploy discipline. (Cost: the floor is
    // reserve/maxSupply, diluted across not-yet-minted Seats, until the collection mints out — an honest,
    // disclosed property, not a bug.)
    uint256 cap = ISeatSupply(address(_seat)).maxSupply();
    require(cap > 0, "zero supply");
    usdg = _usdg;
    seat = _seat;
    backedSupply = cap;
  }

  /// The USDG currently in the reserve.
  function reserve() public view returns (uint256) {
    return usdg.balanceOf(address(this));
  }

  /// What one Seat can redeem for right now — the reserve split across the Seats it still backs.
  function floorPerSeat() public view returns (uint256) {
    return backedSupply == 0 ? 0 : reserve() / backedSupply;
  }

  /// Add USDG to the reserve, raising the floor for every backed Seat. Permissionless — anyone (ops routing
  /// protocol proceeds, or a well-wisher) can strengthen the floor; no one can ever remove funds except a Seat
  /// owner redeeming their own Seat.
  function fund(uint256 amount) external nonReentrant {
    require(amount > 0, "zero amount");
    usdg.safeTransferFrom(msg.sender, address(this), amount);
    emit Funded(msg.sender, amount, floorPerSeat());
  }

  /// Redeem a Seat you own for its floor: locks the Seat in this reserve (forfeiting its membership — Bell
  /// payouts, staking) and pays you its pro-rata USDG share. The Seat must be approved to this contract first.
  /// The floor for remaining holders is unchanged (non-decreasing) by the pro-rata invariant.
  function redeem(uint256 seatId) external nonReentrant returns (uint256 paid) {
    if (backedSupply == 0) revert NothingBacked();
    if (seat.ownerOf(seatId) != msg.sender) revert NotSeatOwner();

    paid = reserve() / backedSupply; // floorPerSeat(), snapshot before mutating
    if (paid == 0) revert NoFloor();

    backedSupply -= 1;
    // Lock the Seat here. We use transferFrom (not safeTransferFrom) because this contract is not an
    // ERC721Receiver. NOTE: the Seat's _update still calls its trusted Bell hook (onSeatTransfer) on this move,
    // so a callback DOES fire — reentrancy safety comes from `nonReentrant` + checks-effects-interactions
    // (backedSupply is decremented before this external call), NOT from any absence of a callback. Do not relax
    // the guard on the assumption the NFT move is callback-free.
    seat.transferFrom(msg.sender, address(this), seatId);
    usdg.safeTransfer(msg.sender, paid);
    emit Redeemed(msg.sender, seatId, paid);
  }
}
