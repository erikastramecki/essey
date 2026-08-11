// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// The DonReserve's live floor — the redemption price the exchange must never undercut.
interface IDonFloor {
    function floorPerDon() external view returns (uint256);
}

/// DonExchange — the Dons' broker desk. A two-sided vault holding an inventory of Dons (seeded with 25% of the
/// collection = 2,222) and an $ESSEY reserve, trading between them at one price. Faithful to StonkBrokers'
/// Anvil AMM and a direct evolution of EsseyExchange (the audited Seat AMM), with two changes the Dons need:
///
///   1. PERCENTAGE fees (StonkBroker-style, softened): 8% on a standard buy/sell, 12% to snipe a specific Don —
///      as a % of `price()`, charged in $ESSEY (the trade currency, so no separate fee token / no swap).
///   2. Fee SPLIT 70% → `feeSink` (the fee→stock router, which DCA-buys Robinhood stock for the staked Dons) /
///      30% → `treasury`. So every trade pays the seated holders.
///
///   - BUY (swap):  pay `price()` + 8% fee ($ESSEY) → receive the next Don from inventory.
///   - SNIPE:       pay `price()` + 12% fee ($ESSEY) → receive a SPECIFIC Don #.
///   - SELL:        return a Don → receive `price()` minus the 8% fee ($ESSEY).
///
/// PRICE = max(donPrice, DonReserve.floorPerDon()) — pinned to the LIVE redemption floor, read from the
/// immutable `floorSource` every trade. The floor only ever rises (DonReserve is fund-only, pro-rata on
/// redeem), so a flat price would eventually sit BELOW it and buy→redeem arbitrage would drain the whole
/// inventory for profit; tracking the live floor (plus the 8% fee) makes that loop strictly unprofitable.
/// `donPrice` (the 300k floor at deploy) survives as a lower bound so the desk never quotes below its
/// seeded economics even if the reserve is briefly thin. Adminless over funds — the only role is `seeder`,
/// which can ONLY pull pre-owned Dons into inventory (float), never touch the reserve or fees.
contract DonExchange is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC721 public immutable don;
    IERC20 public immutable essey; // price + fee currency
    IDonFloor public immutable floorSource; // the DonReserve — its live floor is the price's lower bound
    address public immutable feeSink; // 70% of every fee → the fee→stock router
    address public immutable treasury; // 30% of every fee
    address public immutable seeder; // float manager (add inventory only)

    uint256 public immutable donPrice; // deploy-time price minimum (= the 300k floor at deploy)
    uint256 public immutable swapFeeBps; // 800 = 8% (buy/sell)
    uint256 public immutable snipeFeeBps; // 1200 = 12% (pick a specific Don)
    uint256 public immutable stockShareBps; // 7000 = 70% of each fee → feeSink (stock); rest → treasury

    uint256 internal constant BPS = 10_000;

    uint256[] private _inv; // Don ids currently in inventory
    mapping(uint256 => uint256) private _idxPlus1; // id => (index in _inv) + 1; 0 = not held

    event Seeded(uint256 count);
    event Bought(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee);
    event Sniped(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee);
    event Sold(uint256 indexed id, address indexed seller, uint256 net, uint256 fee);
    event FeeRouted(uint256 toStock, uint256 toTreasury);

    error BadConfig();
    error NotSeeder();
    error EmptyInventory();
    error NotInInventory(uint256 id);
    error SlippageExceeded(uint256 quoted, uint256 bound);

    constructor(
        IERC721 don_,
        IERC20 essey_,
        IDonFloor floorSource_,
        address feeSink_,
        address treasury_,
        address seeder_,
        uint256 donPrice_,
        uint256 swapFeeBps_,
        uint256 snipeFeeBps_,
        uint256 stockShareBps_
    ) {
        if (
            address(don_) == address(0) || address(essey_) == address(0) || address(floorSource_) == address(0)
                || feeSink_ == address(0) || treasury_ == address(0) || seeder_ == address(0) || donPrice_ == 0
                || snipeFeeBps_ < swapFeeBps_ || snipeFeeBps_ > BPS || stockShareBps_ > BPS
        ) revert BadConfig();
        don = don_;
        essey = essey_;
        floorSource = floorSource_;
        feeSink = feeSink_;
        treasury = treasury_;
        seeder = seeder_;
        donPrice = donPrice_;
        swapFeeBps = swapFeeBps_;
        snipeFeeBps = snipeFeeBps_;
        stockShareBps = stockShareBps_;
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

    /// The live trade price: the DonReserve's current redemption floor, never below the deploy-time
    /// `donPrice`. Read fresh on every trade so the desk can never be arbed against a risen floor.
    function price() public view returns (uint256) {
        uint256 floor = floorSource.floorPerDon();
        return floor > donPrice ? floor : donPrice;
    }

    function feeOn(uint256 bps) public view returns (uint256) {
        return (price() * bps) / BPS;
    }

    // ---------------------------------------------------------------- float (seeder)

    /// Pull pre-owned Dons into inventory. Seeder-only (owns the ids + approved). Only ADDS float — never funds.
    function seed(uint256[] calldata ids) external nonReentrant {
        if (msg.sender != seeder) revert NotSeeder();
        for (uint256 i = 0; i < ids.length; i++) {
            don.transferFrom(msg.sender, address(this), ids[i]);
            _add(ids[i]);
        }
        emit Seeded(ids.length);
    }

    // ---------------------------------------------------------------- trade

    /// Buy the next Don from inventory at the live price + 8% fee (all $ESSEY). `maxCost` caps the total
    /// $ESSEY pulled (price + fee): the live `price()` tracks the DonReserve floor, which anyone may raise
    /// permissionlessly, so the caller passes the most they're willing to pay and the trade reverts rather
    /// than over-charging if the floor rose after they signed.
    function buy(uint256 maxCost) external nonReentrant returns (uint256 id) {
        uint256 n = _inv.length;
        if (n == 0) revert EmptyInventory();
        id = _inv[n - 1]; // LIFO — "next" Don
        _remove(id);
        uint256 p = price(); // one read — price and fee priced off the same quote
        uint256 fee = (p * swapFeeBps) / BPS;
        if (p + fee > maxCost) revert SlippageExceeded(p + fee, maxCost);
        essey.safeTransferFrom(msg.sender, address(this), p); // price into the reserve
        _routeFee(fee); // fee pulled from caller and split
        don.transferFrom(address(this), msg.sender, id);
        emit Bought(id, msg.sender, p, fee);
    }

    /// Snipe a specific Don # from inventory at the live price + the 12% premium fee. `maxCost` caps the
    /// total $ESSEY pulled (see `buy`).
    function snipe(uint256 id, uint256 maxCost) external nonReentrant {
        if (!inInventory(id)) revert NotInInventory(id);
        _remove(id);
        uint256 p = price();
        uint256 fee = (p * snipeFeeBps) / BPS;
        if (p + fee > maxCost) revert SlippageExceeded(p + fee, maxCost);
        essey.safeTransferFrom(msg.sender, address(this), p);
        _routeFee(fee);
        don.transferFrom(address(this), msg.sender, id);
        emit Sniped(id, msg.sender, p, fee);
    }

    /// Sell a Don back to inventory: receive the live price minus the 8% fee. The fee is split from the
    /// proceeds (the exchange's reserve funds both), so the seller sends only the Don. `minOut` is the
    /// least net $ESSEY the seller will accept — reverts rather than under-paying if the quote moved.
    function sell(uint256 id, uint256 minOut) external nonReentrant {
        don.transferFrom(msg.sender, address(this), id); // seller owns + approved
        _add(id);
        uint256 p = price();
        uint256 fee = (p * swapFeeBps) / BPS;
        uint256 net = p - fee; // fee < price by construction (swapFeeBps <= 100%)
        if (net < minOut) revert SlippageExceeded(net, minOut);
        uint256 toStock = (fee * stockShareBps) / BPS;
        uint256 toTreasury = fee - toStock;
        if (toStock != 0) essey.safeTransfer(feeSink, toStock);
        if (toTreasury != 0) essey.safeTransfer(treasury, toTreasury);
        essey.safeTransfer(msg.sender, net);
        emit FeeRouted(toStock, toTreasury);
        emit Sold(id, msg.sender, net, fee);
    }

    // ---------------------------------------------------------------- internals

    /// Pull `fee` $ESSEY from the caller and split it 70% → feeSink (stock) / 30% → treasury.
    function _routeFee(uint256 fee) internal {
        if (fee == 0) return;
        essey.safeTransferFrom(msg.sender, address(this), fee);
        uint256 toStock = (fee * stockShareBps) / BPS;
        uint256 toTreasury = fee - toStock;
        if (toStock != 0) essey.safeTransfer(feeSink, toStock);
        if (toTreasury != 0) essey.safeTransfer(treasury, toTreasury);
        emit FeeRouted(toStock, toTreasury);
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

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
