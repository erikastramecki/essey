// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Bell} from "./Bell.sol";

/// The Exchange — Essey's Seat AMM. A two-sided flat-price vault: it holds an inventory of Seats and an
/// $ESSEY reserve, and trades between them at a fixed price. "A Seat on the Exchange."
///
///   - BUY (swap):  pay `seatPrice` $ESSEY + `swapFee` → receive the next Seat from inventory.
///   - SNIPE:       pay `seatPrice` $ESSEY + `snipeFee` (a premium) → receive a SPECIFIC Seat #.
///   - SELL:        return a Seat to inventory + pay `sellFee` → receive `seatPrice` $ESSEY back.
///
/// Faithful to StonkBrokers' Anvil AMM: a FLAT price (no bonding curve), with float — the inventory the
/// Exchange holds — as the scarcity dial (their vault holds ~50% of the collection). Every trade fee is
/// charged in the **Bell's reward token** and split `boosterShareBps` to the Bell (fed by plain transfer
/// → grows the pot) / remainder to treasury. So the Exchange is a primary fee engine for the Bell.
///
/// v1 simplifications (deliberate, documented): flat immutable price + flat immutable fees, so there is
/// no price/fee oracle to manipulate and no admin to move them. A %-of-ETH-notional fee with a
/// TWAP-sandwich oracle (StonkBrokers' model) is a possible v2 refinement.
///
/// Adminless over funds. The only privileged role is `seeder`, which can ONLY pull pre-owned Seats into
/// inventory (float management) — it can never touch the $ESSEY reserve, fees, or anyone's assets.
/// Decoupled from minting: the Exchange is not the Seat minter; it acquires float via `seed` and via
/// sell-backs, exactly like StonkBrokers' vault.
contract EsseyExchange is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC721 public immutable seat;
    IERC20 public immutable essey; // Seat price currency (the two-sided reserve asset)
    IERC20 public immutable feeToken; // trade-fee currency == Bell.reward(), so fees feed the pot
    Bell public immutable bell;
    address public immutable treasury;
    address public immutable seeder;

    uint256 public immutable seatPrice; // flat $ESSEY price of one Seat
    uint256 public immutable swapFee; // feeToken fee to buy the next Seat
    uint256 public immutable snipeFee; // feeToken fee to pick an exact Seat (>= swapFee)
    uint256 public immutable sellFee; // feeToken fee to sell a Seat back
    uint256 public immutable boosterShareBps; // share of every fee routed to the Bell

    uint256 internal constant BPS = 10_000;

    uint256[] private _inv; // Seat ids currently in inventory
    mapping(uint256 => uint256) private _idxPlus1; // id => (index in _inv) + 1; 0 = not held

    event Seeded(uint256 count);
    event Bought(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee);
    event Sniped(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee);
    event Sold(uint256 indexed id, address indexed seller, uint256 price, uint256 fee);
    event FeeRouted(uint256 toBell, uint256 toTreasury);

    error BadConfig();
    error NotSeeder();
    error EmptyInventory();
    error NotInInventory(uint256 id);

    constructor(
        IERC721 seat_,
        IERC20 essey_,
        Bell bell_,
        address treasury_,
        address seeder_,
        uint256 seatPrice_,
        uint256 swapFee_,
        uint256 snipeFee_,
        uint256 sellFee_,
        uint256 boosterShareBps_
    ) {
        if (
            address(seat_) == address(0) || address(essey_) == address(0) || address(bell_) == address(0)
                || treasury_ == address(0) || seeder_ == address(0) || seatPrice_ == 0
                || snipeFee_ < swapFee_ || boosterShareBps_ > BPS
        ) revert BadConfig();
        // Fees must be in the Bell's reward token, so routing to the Bell is a plain transfer that grows
        // the pot. Mismatch here would send fees the Bell never counts.
        if (essey_ == IERC20(address(bell_.reward()))) revert BadConfig(); // price and fee assets must differ
        // Deployment-coherence guard: this Exchange must serve the SAME Seat collection the Bell rewards,
        // or fees would flow to an unrelated pot. Makes a mis-wired deploy un-deployable, not just checked.
        if (address(bell_.seat()) != address(seat_)) revert BadConfig();
        feeToken = IERC20(address(bell_.reward()));

        seat = seat_;
        essey = essey_;
        bell = bell_;
        treasury = treasury_;
        seeder = seeder_;
        seatPrice = seatPrice_;
        swapFee = swapFee_;
        snipeFee = snipeFee_;
        sellFee = sellFee_;
        boosterShareBps = boosterShareBps_;
    }

    // ---------------------------------------------------------------- views
    function inventoryCount() external view returns (uint256) {
        return _inv.length;
    }

    function inventoryAt(uint256 i) external view returns (uint256) {
        return _inv[i];
    }

    function inInventory(uint256 id) public view returns (bool) {
        return _idxPlus1[id] != 0;
    }

    function esseyReserve() external view returns (uint256) {
        return essey.balanceOf(address(this));
    }

    // ---------------------------------------------------------------- float (seeder)

    /// Pull pre-owned Seats into inventory. Seeder-only; the seeder must own the ids and have approved
    /// the Exchange. This is the only privileged action and it can only ADD float — never move funds.
    function seed(uint256[] calldata ids) external nonReentrant {
        if (msg.sender != seeder) revert NotSeeder();
        for (uint256 i = 0; i < ids.length; i++) {
            seat.transferFrom(msg.sender, address(this), ids[i]);
            _add(ids[i]);
        }
        emit Seeded(ids.length);
    }

    // ---------------------------------------------------------------- trade

    /// Buy the next Seat from inventory at the flat price + swap fee.
    function buy() external nonReentrant returns (uint256 id) {
        uint256 n = _inv.length;
        if (n == 0) revert EmptyInventory();
        id = _inv[n - 1]; // LIFO — "next" Seat
        _remove(id);
        essey.safeTransferFrom(msg.sender, address(this), seatPrice);
        _takeFee(swapFee);
        seat.transferFrom(address(this), msg.sender, id);
        emit Bought(id, msg.sender, seatPrice, swapFee);
    }

    /// Snipe a specific Seat # from inventory at the flat price + the (premium) snipe fee.
    function snipe(uint256 id) external nonReentrant {
        if (!inInventory(id)) revert NotInInventory(id);
        _remove(id);
        essey.safeTransferFrom(msg.sender, address(this), seatPrice);
        _takeFee(snipeFee);
        seat.transferFrom(address(this), msg.sender, id);
        emit Sniped(id, msg.sender, seatPrice, snipeFee);
    }

    /// Sell a Seat back to inventory for the flat price, paying the sell fee. Reverts if the reserve
    /// can't cover the price (a normal AMM liquidity constraint).
    function sell(uint256 id) external nonReentrant {
        seat.transferFrom(msg.sender, address(this), id); // seller must own + approve
        _add(id);
        _takeFee(sellFee);
        essey.safeTransfer(msg.sender, seatPrice);
        emit Sold(id, msg.sender, seatPrice, sellFee);
    }

    // ---------------------------------------------------------------- internals

    /// Pull `fee` in the Bell's reward token from the caller, route the booster share to the Bell (grows
    /// the pot) and the rest to treasury.
    function _takeFee(uint256 fee) internal {
        if (fee == 0) return;
        feeToken.safeTransferFrom(msg.sender, address(this), fee);
        uint256 toBell = (fee * boosterShareBps) / BPS;
        if (toBell != 0) feeToken.safeTransfer(address(bell), toBell);
        uint256 toTreasury = fee - toBell;
        if (toTreasury != 0) feeToken.safeTransfer(treasury, toTreasury);
        emit FeeRouted(toBell, toTreasury);
    }

    function _add(uint256 id) internal {
        _inv.push(id);
        _idxPlus1[id] = _inv.length; // index + 1
    }

    function _remove(uint256 id) internal {
        uint256 i = _idxPlus1[id] - 1; // caller guarantees present
        uint256 last = _inv[_inv.length - 1];
        _inv[i] = last;
        _idxPlus1[last] = i + 1;
        _inv.pop();
        _idxPlus1[id] = 0;
    }

    /// Accept Seats routed in by the seed/sell paths (which use transferFrom, not safeTransfer, so this
    /// is defensive); direct safe-transfers into the Exchange are accepted but only enter inventory via
    /// the seed/sell functions.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
