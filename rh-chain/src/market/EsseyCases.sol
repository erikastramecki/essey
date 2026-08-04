// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StaleFeedGuard} from "../StaleFeedGuard.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {Bell} from "./Bell.sol";

/// EsseyCases — the "401k pack": buy a Case in $ESSEY, draw a real stock, keep it / borrow against
/// it / sell it back. The CS:GO reflex pointed at retirement assets instead of skins.
///
/// VARIANT (deliberate, reg-driven). This is the FAIR-VALUE variant ONLY: every prize unit in the
/// bankroll is seeded at roughly one Case's worth of a listed stock, so the draw randomizes *which*
/// stock you get — never *how much value*. There is no multiplier, no jackpot, no house edge on the
/// draw itself. The multiplier "degen" variant is explicitly NOT built here (it needs a hardened VRF
/// and jurisdiction gating; see docs/TOKENOMICS-essey.md).
///
/// ENTROPY (deliberate, bounded — read the whole model). The draw seed is the blockhash of a block
/// committed at buy time (`drawBlock = block.number + 1`), so the outcome is unpredictable AT BUY.
/// Once that block exists the outcome is public, which is where naive designs leak: any post-draw
/// optionality (re-rolls, unlimited open timing) lets a buyer select on price drift between units —
/// "fair value at seed time" does not mean equal value forever. This contract closes that:
///   - There are NO re-rolls. A case must be opened while `blockhash(drawBlock)` is live (the EVM's
///     256-block window — and open-immediately IS the gacha product flow).
///   - An EXPIRED case is never a fresh draw: `claimExpired` pays out the CURRENT LOWEST-oracle-value
///     unit in inventory, and only until CLAIM_TTL — after that the case is sweepable and the prize
///     stays in the pool. Abandoning a draw can never beat the floor, and the floor can't be farmed
///     over a long horizon.
///   - The honest bound on EVERY remaining selection lever (open-timing within the window, self
///     sell-backs reshaping the array, sequencer bias over block contents, expired-claim timing
///     within the TTL) is the same quantity: the DISPERSION of unit values in inventory — accumulated
///     drift since each unit was seeded, NOT drift over the action window. The load-bearing control
///     is therefore operational: the bankroll must keep seeding units near par so dispersion stays
///     small relative to the sell-back spread (floored at MIN_SPREAD_BPS, which every extraction
///     round-trip pays). "Uniform value" is an approximation MAINTAINED by re-seeding, not a static
///     invariant — treat dispersion as a monitored risk knob.
///   - The moment prizes are deliberately non-uniform (multipliers, jackpots), blockhash entropy is
///     insufficient no matter the discipline and must be replaced with a hardened VRF — that is a
///     hard gate for the degen variant, not a tuning knob.
///
/// PROVABLY-SOLVENT BANKROLL. `buy` reverts unless the on-chain prize inventory exceeds the number
/// of unopened Cases — every unopened Case is backed by a real, already-deposited prize unit. "The
/// house reserved this prize in real inventory before you opened" is an invariant, not a promise.
///
/// TWO-SIDED FEES, both feeding the Bell:
///   - BUY:  `casePrice` in $ESSEY goes to treasury (the access-token sink — you spend the volatile
///           token, you receive stock), plus `buyFee` in the Bell's reward token split
///           `boosterShareBps` → the Bell pot / remainder → treasury (the Exchange's fee pattern).
///   - SELL-BACK: return a full prize unit of a listed stock and receive its ORACLE value minus
///           `spreadBps`, paid in base (the reward stable). The spread's booster share goes to the
///           Bell; the rest stays in the buyback reserve (retained bankroll). The returned stock
///           re-enters inventory as a fresh prize unit.
///
/// ORACLE DISCIPLINE. Sell-back inherits StaleFeedGuard end-to-end: silent feeds, incomplete rounds,
/// holidays, and off-session all revert. Off-hours there is no verifiable equity price, so there is
/// no off-hours buyback — declining is always safe; overpaying never is (StockConverter's rule).
///
/// ROLES. `bankroll` can only ADD: list stocks (append-only), deposit prize units, fund the buyback
/// reserve. It can never withdraw, reprice, or touch a user's Case. Treasury is immutable. There is
/// no owner, pause, or upgrade; funds committed to the game stay in the game.
contract EsseyCases is StaleFeedGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Unit {
        address token; // a listed stock
        uint256 amount; // that stock's fixed unit size
    }

    struct Case {
        address buyer;
        uint64 drawBlock; // blockhash(drawBlock) seeds the draw; openable when block.number > drawBlock
        uint64 boughtAt; // purchase timestamp; expired-claim and abandonment sweep key off this
        bool opened;
    }

    struct StockInfo {
        uint256 unitAmount; // fixed prize-unit size for this stock
        uint8 tokenDecimals;
        bool listed;
    }

    IERC20 public immutable essey; // Case price currency (access token — sunk to treasury)
    IERC20 public immutable base; // buyback payout currency == Bell.reward(), so fees feed the pot
    uint8 public immutable baseDecimals;
    Bell public immutable bell;
    address public immutable treasury;
    address public immutable bankroll;
    /// Optional convenience settler: may open a Case on the buyer's behalf, with the prize ALWAYS
    /// delivered to the stored buyer (never the caller), so the buyer signs only the buy. It cannot
    /// withdraw, reprice, or touch funds, and the buyer can always open (or claimExpired) themselves,
    /// so the keeper is purely additive. It is EXPECTED to open promptly once the draw is live (the
    /// intended flow); the contract does not force a specific block, and the only thing an open-timing
    /// choice can shift is bounded by inventory dispersion (see the header). Keeper uptime within the
    /// 256-block window is therefore operationally load-bearing: past it the buyer falls back to the
    /// floor via claimExpired. Zero => buyer-only.
    address public immutable keeper;

    uint256 public immutable casePrice; // flat $ESSEY price of one Case
    uint256 public immutable buyFee; // base-token fee on buy
    uint256 public immutable spreadBps; // sell-back discount off oracle value
    uint256 public immutable boosterShareBps; // share of each fee leg routed to the Bell

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_SPREAD_BPS = 2_000; // 20% ceiling — a "discount", not a rug
    /// Floor: the sell-back round trip crosses TWO oracle deviation bands (stock read high, base read
    /// low — 0.5% each on this chain's feeds compounds to ~100.5 bps of oracle-vs-market edge), so the
    /// spread floor must clear both legs plus latency margin, or buy-on-market -> sellBack becomes a
    /// repeatable extraction of the reserve inside the bands.
    uint256 internal constant MIN_SPREAD_BPS = 150;
    /// How long an EXPIRED case remains claimable (at the floor) before anyone may sweep it back to
    /// the prize pool. Bounds the expired-claim option: without a deadline, "claim the floor whenever
    /// I like" is an unbounded American option on min(inventory value) — a patient buyer waits for the
    /// cheap units to drain and claims a floor that beats the draw they abandoned. Seven days is long
    /// enough for any honest claimer (incl. off-session waits) and short enough that inventory
    /// composition rarely shifts in their favor.
    uint256 internal constant CLAIM_TTL = 7 days;

    mapping(address => StockInfo) public stocks;
    Unit[] private _units; // the prize inventory (uniform draw)
    mapping(uint256 => Case) public cases;
    uint256 public nextCaseId;
    uint256 public unopened; // Cases bought but not yet opened — each must be inventory-backed

    event StockListed(address indexed token, address feed, uint256 unitAmount);
    event UnitsSeeded(address indexed token, uint256 count);
    event BuybackFunded(uint256 amount);
    event CaseBought(uint256 indexed caseId, address indexed buyer, uint64 drawBlock);
    event CaseOpened(uint256 indexed caseId, address indexed buyer, address indexed token, uint256 amount);
    event ExpiredClaimed(uint256 indexed caseId, address indexed buyer, address indexed token, uint256 amount);
    event CaseSwept(uint256 indexed caseId, address indexed buyer);
    event SoldBack(address indexed seller, address indexed token, uint256 amount, uint256 paid, uint256 toBell);
    event FeeRouted(uint256 toBell, uint256 toTreasury);

    error BadConfig();
    error NotBankroll();
    error AlreadyListed();
    error NotListed();
    error NotInSession();
    error NoBackingInventory();
    error NotYourCase();
    error AlreadyOpened();
    error DrawNotReady();
    error DrawExpired();
    error DrawNotExpired();
    error ClaimLapsed();
    error NoPriceableFloor();

    constructor(
        IERC20 essey_,
        Bell bell_,
        AggregatorV3Interface baseFeed_,
        AggregatorV3Interface sequencerUptimeFeed_,
        address treasury_,
        address bankroll_,
        uint256 casePrice_,
        uint256 buyFee_,
        uint256 spreadBps_,
        uint256 boosterShareBps_,
        address keeper_
    ) StaleFeedGuard(sequencerUptimeFeed_) {
        if (
            address(essey_) == address(0) || address(bell_) == address(0) || address(baseFeed_) == address(0)
                || treasury_ == address(0) || bankroll_ == address(0) || casePrice_ == 0
                || spreadBps_ < MIN_SPREAD_BPS || spreadBps_ > MAX_SPREAD_BPS || boosterShareBps_ > BPS
        ) revert BadConfig();
        // The buyback/fee asset must be the Bell's reward token so routing to the Bell is a plain
        // transfer that grows the pot — and it must differ from the access token.
        IERC20 base_ = IERC20(address(bell_.reward()));
        if (essey_ == base_) revert BadConfig();

        essey = essey_;
        bell = bell_;
        base = base_;
        baseDecimals = IERC20Metadata(address(base_)).decimals();
        treasury = treasury_;
        bankroll = bankroll_;
        casePrice = casePrice_;
        buyFee = buyFee_;
        spreadBps = spreadBps_;
        boosterShareBps = boosterShareBps_;
        keeper = keeper_; // zero is allowed: buyer-only opens, as before

        uint8 bfd = baseFeed_.decimals();
        if (bfd > 18) revert BadConfig(); // normalization assumes <= 18 (Chainlink uses 8)
        _setFeed(address(base_), baseFeed_, FEED_HEARTBEAT + STALENESS_GRACE, bfd);
    }

    // ---------------------------------------------------------------- views

    function inventoryCount() external view returns (uint256) {
        return _units.length;
    }

    function unitAt(uint256 i) external view returns (address token, uint256 amount) {
        Unit memory u = _units[i];
        return (u.token, u.amount);
    }

    /// The backing invariant, exposed: prize units not yet spoken for by an unopened Case.
    function freeInventory() public view returns (uint256) {
        return _units.length - unopened; // buy() maintains _units.length >= unopened
    }

    // ---------------------------------------------------------------- bankroll (add-only)

    /// Append-only stock listing: token + Chainlink feed + the fixed prize-unit size. Immutable once
    /// listed, so a stock users hold can't have its feed or unit size swapped underneath them.
    function listStock(address token, AggregatorV3Interface feed, uint256 unitAmount) external nonReentrant {
        if (msg.sender != bankroll) revert NotBankroll();
        if (token == address(0) || address(feed) == address(0) || token == address(base) || unitAmount == 0) {
            revert BadConfig();
        }
        if (stocks[token].listed) revert AlreadyListed();
        uint8 fd = feed.decimals();
        uint8 td = IERC20Metadata(token).decimals();
        // Both bounded <= 18: feed normalization assumes it, and 10**tokenDecimals in the sell-back
        // math must never overflow (a >77-decimals token would permanently brick its own buyback).
        if (fd > 18 || td > 18) revert BadConfig();
        stocks[token] = StockInfo(unitAmount, td, true);
        _setFeed(token, feed, FEED_HEARTBEAT + STALENESS_GRACE, fd);
        emit StockListed(token, address(feed), unitAmount);
    }

    /// Deposit `count` prize units of a listed stock into the inventory. Pulls the stock from the
    /// bankroll; add-only — there is no withdrawal path for inventory, ever.
    function seedUnits(address token, uint256 count) external nonReentrant {
        if (msg.sender != bankroll) revert NotBankroll();
        StockInfo memory s = stocks[token];
        if (!s.listed) revert NotListed();
        if (count == 0) revert BadConfig();
        IERC20(token).safeTransferFrom(msg.sender, address(this), s.unitAmount * count);
        for (uint256 i = 0; i < count; i++) {
            _units.push(Unit(token, s.unitAmount));
        }
        emit UnitsSeeded(token, count);
    }

    /// Fund the buyback reserve with base. Anyone may strengthen the bankroll; no one can drain it.
    function fundBuyback(uint256 amount) external nonReentrant {
        base.safeTransferFrom(msg.sender, address(this), amount);
        emit BuybackFunded(amount);
    }

    // ---------------------------------------------------------------- buy / open

    /// Buy a Case: $ESSEY price → treasury, buy fee → Bell/treasury split. Reverts unless a real
    /// prize unit exists in inventory beyond those already owed to unopened Cases.
    function buy() external nonReentrant returns (uint256 caseId) {
        if (_units.length < unopened + 1) revert NoBackingInventory();
        unopened += 1;
        caseId = nextCaseId++;
        uint64 drawBlock = uint64(block.number + 1);
        cases[caseId] = Case(msg.sender, drawBlock, uint64(block.timestamp), false);

        essey.safeTransferFrom(msg.sender, treasury, casePrice);
        _takeFee(buyFee);
        emit CaseBought(caseId, msg.sender, drawBlock);
    }

    /// Open a Case: the committed blockhash seeds a uniform draw over the inventory; the drawn stock
    /// unit is delivered to the BUYER. Callable by the buyer or the keeper (a convenience settler) — the
    /// prize always goes to the stored buyer, so a keeper can reveal on their behalf without the buyer
    /// signing a second transaction. Only these two callers, so no third party can grief the buyer's
    /// draw timing (the drawn index depends on inventory state at open, bounded by dispersion).
    function open(uint256 caseId) external nonReentrant returns (address token, uint256 amount) {
        Case storage c = cases[caseId];
        if (c.buyer == address(0) || (msg.sender != c.buyer && msg.sender != keeper)) revert NotYourCase();
        if (c.opened) revert AlreadyOpened();
        if (block.number <= c.drawBlock) revert DrawNotReady();
        bytes32 bh = blockhash(c.drawBlock);
        if (bh == bytes32(0)) revert DrawExpired(); // past the 256-block window — claimExpired instead

        c.opened = true;
        unopened -= 1;
        uint256 idx = uint256(keccak256(abi.encodePacked(bh, caseId))) % _units.length;
        Unit memory u = _units[idx];
        // swap-and-pop the drawn unit out of inventory
        _units[idx] = _units[_units.length - 1];
        _units.pop();

        IERC20(u.token).safeTransfer(c.buyer, u.amount);
        emit CaseOpened(caseId, c.buyer, u.token, u.amount);
        return (u.token, u.amount);
    }

    /// Claim a Case whose draw block fell out of the EVM's 256-block blockhash window. This is NOT a
    /// re-roll: an expired case pays out the CURRENT LOWEST-oracle-value unit in inventory, so a buyer
    /// who abandons a draw can never do better than the cheapest thing in the pool — and only until
    /// CLAIM_TTL, so there is no long-horizon option on the floor either (a patient claimer can't wait
    /// for cheap inventory to drain out from under the floor). Within those bounds the residual is
    /// inventory value DISPERSION over at most seven days — the load-bearing control is the bankroll
    /// re-seeding units near par so dispersion stays small (see the header). A design with free
    /// re-rolls here would let buyers select on drift and drain the bankroll. Oracle-priced and
    /// therefore session-gated: off-hours there is no verifiable floor, so the claim waits (the TTL is
    /// sized so waiting for a session never eats the window).
    function claimExpired(uint256 caseId) external nonReentrant returns (address token, uint256 amount) {
        Case storage c = cases[caseId];
        if (c.buyer != msg.sender) revert NotYourCase();
        if (c.opened) revert AlreadyOpened();
        if (block.number <= c.drawBlock || blockhash(c.drawBlock) != bytes32(0)) revert DrawNotExpired();
        if (block.timestamp > c.boughtAt + CLAIM_TTL) revert ClaimLapsed();

        c.opened = true;
        unopened -= 1;
        uint256 idx = _lowestValueIndex();
        Unit memory u = _units[idx];
        _units[idx] = _units[_units.length - 1];
        _units.pop();

        IERC20(u.token).safeTransfer(msg.sender, u.amount);
        emit ExpiredClaimed(caseId, msg.sender, u.token, u.amount);
        return (u.token, u.amount);
    }

    /// Free the backing of a Case whose expired-claim window has ALSO lapsed. Anyone may call it: the
    /// buyer forfeited by ignoring both the open window and the CLAIM_TTL, the prize unit simply stays
    /// in the pool (nothing is transferred anywhere), and freeing `unopened` lets new Cases be bought
    /// against that unit again. Without this, abandoned Cases would lock inventory forever.
    function sweepAbandoned(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.buyer == address(0)) revert NotYourCase(); // nonexistent
        if (c.opened) revert AlreadyOpened();
        // BOTH clocks must have lapsed. The TTL is wall-time and the draw window is block-count;
        // they only decouple when block production stalls (a multi-day halt) — in which case a
        // still-openable draw must not be sweepable out from under its buyer on resume. The TTL
        // clock not pausing during such a halt is the accepted flip side (wall-clock TTLs can't
        // promise liveness the chain itself doesn't have).
        if (block.number <= c.drawBlock || blockhash(c.drawBlock) != bytes32(0)) revert DrawNotExpired();
        if (block.timestamp <= c.boughtAt + CLAIM_TTL) revert DrawNotExpired();
        c.opened = true;
        unopened -= 1;
        emit CaseSwept(caseId, c.buyer);
    }

    /// Index of the lowest-oracle-value unit in inventory. Per-token values are memoized (inventory
    /// holds many units of few tokens). Session gating fails closed: an off-session equity price
    /// reverts the scan (claim waits for a session). A feed that REVERTS outright — stale past the
    /// broken-oracle bound, decommissioned, incomplete round — excludes its token from floor candidacy
    /// instead of bricking every expired claim forever (a dead feed would otherwise strand all
    /// claimers while any unit of that token remained, and inventory has no removal path). The cost of
    /// skipping is a floor read slightly above the true floor in exactly the broken-feed regime —
    /// bounded by CLAIM_TTL and accepted over a permanent global brick. If NO token is priceable, the
    /// claim reverts and waits.
    function _lowestValueIndex() internal view returns (uint256 best) {
        uint256 n = _units.length; // >= 1: the claiming case was unopened, so backing exists
        address[] memory toks = new address[](n);
        uint256[] memory vals = new uint256[](n);
        uint256 nTok;
        uint256 bestVal = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            address t = _units[i].token;
            uint256 v;
            bool seen;
            for (uint256 j = 0; j < nTok; j++) {
                if (toks[j] == t) {
                    v = vals[j];
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                // External self-call so a reverting feed can be caught; priceOf is view => STATICCALL,
                // no reentrancy surface.
                try this.priceOf(t) returns (uint256 px, uint8 fd, bool inSession) {
                    if (!inSession) revert NotInSession(); // verifiable-but-closed market: wait
                    StockInfo memory s = stocks[t];
                    v = (s.unitAmount * (px * 10 ** (18 - fd))) / 10 ** s.tokenDecimals; // USD, 1e18
                } catch {
                    v = type(uint256).max; // dead feed: never the floor, never a global brick
                }
                toks[nTok] = t;
                vals[nTok] = v;
                nTok++;
            }
            if (v < bestVal) {
                bestVal = v;
                best = i;
            }
        }
        if (bestVal == type(uint256).max) revert NoPriceableFloor();
    }

    // ---------------------------------------------------------------- sell-back

    /// Return one full prize unit of a listed stock; receive its oracle USD value minus the spread,
    /// paid in base from the buyback reserve. The spread's booster share feeds the Bell; the stock
    /// re-enters inventory as a fresh unit. Session-gated: no verifiable price, no buyback.
    function sellBack(address token) external nonReentrant returns (uint256 paid) {
        StockInfo memory s = stocks[token];
        if (!s.listed) revert NotListed();

        (uint256 basePx, uint8 baseFeedDec,) = priceOf(address(base));
        (uint256 stockPx, uint8 stockFeedDec, bool inSession) = priceOf(token);
        if (!inSession) revert NotInSession();

        // Oracle value of one unit, in base units (StockConverter's normalization, inverted leg).
        uint256 usdValue18 = (s.unitAmount * (stockPx * 10 ** (18 - stockFeedDec))) / 10 ** s.tokenDecimals;
        uint256 gross = (usdValue18 * 10 ** baseDecimals) / (basePx * 10 ** (18 - baseFeedDec));
        paid = (gross * (BPS - spreadBps)) / BPS;
        uint256 spread = gross - paid;
        uint256 toBell = (spread * boosterShareBps) / BPS;

        IERC20(token).safeTransferFrom(msg.sender, address(this), s.unitAmount);
        _units.push(Unit(token, s.unitAmount)); // back into the prize pool
        base.safeTransfer(msg.sender, paid); // reverts if the reserve can't cover — a liquidity constraint
        if (toBell != 0) base.safeTransfer(address(bell), toBell);
        // The rest of the spread stays in the reserve: retained bankroll, strengthening future buybacks.
        emit SoldBack(msg.sender, token, s.unitAmount, paid, toBell);
    }

    // ---------------------------------------------------------------- internals

    /// Buy-fee routing — identical to the Exchange: booster share grows the Bell pot by plain
    /// transfer of the reward token, remainder to treasury.
    function _takeFee(uint256 fee) internal {
        if (fee == 0) return;
        base.safeTransferFrom(msg.sender, address(this), fee);
        uint256 toBell = (fee * boosterShareBps) / BPS;
        if (toBell != 0) base.safeTransfer(address(bell), toBell);
        uint256 toTreasury = fee - toBell;
        if (toTreasury != 0) base.safeTransfer(treasury, toTreasury);
        emit FeeRouted(toBell, toTreasury);
    }
}
