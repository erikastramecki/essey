// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// The Don's fixed cap. The reserve reads it directly so `backedSupply` is pinned to the true maximum on-chain.
interface IDonSupply {
  function maxSupply() external view returns (uint256);
}

/// DonReserve — a hard, rising price FLOOR for Dons, in $ESSEY. A faithful reuse of SeatReserve (the audited
/// Seat floor), with $ESSEY as the reserve asset and the Don as the backed NFT.
///
/// Every Don is backed by a share of an $ESSEY reserve: a Don's floor is `reserve / backedSupply`. Fund the
/// reserve with 30% of supply (2,666,666,666 $ESSEY) against the 8,888 cap and the floor is 300,000 $ESSEY/Don.
/// Anyone may `fund()` (raising the floor for everyone — e.g. protocol proceeds); a Don's owner may `redeem()`
/// it to lock the Don here and claim its floor share. Because redemption is always open at the floor, a Don can
/// never trade below it (ARBITRAGE) — this is the backstop the Don↔$ESSEY AMM's price is anchored to. The floor
/// RISES as the reserve is funded and never falls (the pro-rata invariant keeps `reserve/backedSupply` unchanged
/// on redeem; integer dust stays in the reserve).
///
/// DELIBERATELY MINIMAL & IMMUTABLE: no owner, no admin, no upgrade, no setter on `backedSupply` (which would be
/// a rug). `backedSupply` is set once to the Don's on-chain cap and only ever decrements via `redeem`.
contract DonReserve is ReentrancyGuard {
  using SafeERC20 for IERC20;

  IERC20 public immutable essey; // the reserve asset (a Don's floor is paid in this)
  IERC721 public immutable don; // the Don NFT this backs
  uint256 public backedSupply; // Dons still backed by the reserve (init = the Don cap; -1 per redeem)

  event Funded(address indexed from, uint256 amount, uint256 newFloorPerDon);
  event Redeemed(address indexed owner, uint256 indexed donId, uint256 paid);

  error NoFloor();
  error NotDonOwner();
  error NothingBacked();

  constructor(IERC20 _essey, IERC721 _don) {
    require(address(_essey) != address(0) && address(_don) != address(0), "zero addr");
    // Pin backedSupply to the Don's on-chain cap, NOT a passed-in value — backing the full maxSupply is the only
    // theft-proof choice: since Dons can never exceed maxSupply, an early redeemer can never drain a share funded
    // for a Don that still can't redeem. (Cost: the floor is reserve/maxSupply, diluted across not-yet-minted
    // Dons, until the collection mints out — an honest, disclosed property.)
    uint256 cap = IDonSupply(address(_don)).maxSupply();
    require(cap > 0, "zero supply");
    essey = _essey;
    don = _don;
    backedSupply = cap;
  }

  /// The $ESSEY currently in the reserve.
  function reserve() public view returns (uint256) {
    return essey.balanceOf(address(this));
  }

  /// What one Don can redeem for right now — the reserve split across the Dons it still backs.
  function floorPerDon() public view returns (uint256) {
    return backedSupply == 0 ? 0 : reserve() / backedSupply;
  }

  /// Add $ESSEY to the reserve, raising the floor for every backed Don. Permissionless — anyone (ops routing
  /// protocol proceeds, or a well-wisher) can strengthen the floor; no one can remove funds except a Don owner
  /// redeeming their own Don.
  function fund(uint256 amount) external nonReentrant {
    require(amount > 0, "zero amount");
    essey.safeTransferFrom(msg.sender, address(this), amount);
    emit Funded(msg.sender, amount, floorPerDon());
  }

  /// Redeem a Don you own for its floor: locks the Don in this reserve (forfeiting its membership — Bell payouts,
  /// staking) and pays you its pro-rata $ESSEY share. The Don must be approved to this contract first. The floor
  /// for remaining holders is unchanged (non-decreasing) by the pro-rata invariant.
  function redeem(uint256 donId) external nonReentrant returns (uint256 paid) {
    if (backedSupply == 0) revert NothingBacked();
    if (don.ownerOf(donId) != msg.sender) revert NotDonOwner();

    paid = reserve() / backedSupply; // floorPerDon(), snapshot before mutating
    if (paid == 0) revert NoFloor();

    backedSupply -= 1;
    // Lock the Don here. transferFrom (not safeTransferFrom) — this contract is not an ERC721Receiver. The Don's
    // _update still fires its trusted Bell hook (onSeatTransfer) on this move, so a callback DOES fire —
    // reentrancy safety is `nonReentrant` + checks-effects-interactions (backedSupply decremented before the
    // external call), NOT any absence of a callback.
    don.transferFrom(msg.sender, address(this), donId);
    essey.safeTransfer(msg.sender, paid);
    emit Redeemed(msg.sender, donId, paid);
  }
}
