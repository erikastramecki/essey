// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StaleFeedGuard} from "../StaleFeedGuard.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IConverter} from "./IConverter.sol";

/// BundleConverter — the Bell's claim-edge converter, INVENTORY variant. Turns a Seat's USDG payout
/// into real tokenized stock delivered straight to its Vault, so members are "paid in stock" the way
/// the competitor's Clock-In pays a basket — but on a strictly safer footing.
///
/// WHY INVENTORY, NOT A SWAP. The sibling `StockConverter` swaps base->stock through a Uniswap route;
/// Robinhood Chain testnet has no such pool, and even on mainnet tokenized-equity DEX liquidity is
/// thin and manipulable. This converter instead holds a stock RESERVE (seeded add-only by the
/// bankroll, exactly like EsseyCases' prize inventory) and pays out of it at the SAME Chainlink,
/// session-gated, fail-closed price the lending core and Cases already use. No router, no pool, no
/// custody of base at rest.
///
/// TWO PAYOUT SHAPES, one interface. `convert(amountIn, target, recipient)`:
///   - target == a listed stock  -> pay that single stock (the member's opt-in choice).
///   - target == BUNDLE           -> split the payout into equal parts across the configured basket
///                                   and pay each (the automatic default; the Bell routes unset Seats
///                                   here via its `defaultPayout`).
///
/// FAILS CLOSED, SO THE BELL FAILS OPEN. Off US-market-hours there is no verifiable equity price, a
/// silent/broken feed reverts, and a depleted reserve reverts the transfer. ANY revert here is caught
/// by the Bell, which then pays the base asset (USDG) instead — a payout is never blocked by the
/// stock leg. Declining is always safe; overpaying never is.
///
/// CALLER-GATED. `convert` is callable ONLY by the Bell (wired once via `initBell`, since the Bell
/// takes the converter in its own constructor and can't be known at converter-deploy time). This is
/// load-bearing: the converter holds a stock reserve, so an ungated `convert` would be a public
/// redeem-at-oracle desk anyone could drain (or grief to zero, freely when spread is 0). Gated, the
/// reserve is only ever spent paying a Seat its own reserved payout.
///
/// CUSTODY. None of the base asset at rest: every USDG that arrives in `convert` is forwarded to the
/// treasury in the same call (ops re-seed the stock reserve from it). The stock reserve is the only
/// thing held, and it has NO public withdrawal path — the Bell-gated `convert` aside, the bankroll can
/// only ADD.
///
/// ROLES (minimal). `bankroll` can only ADD (list a stock append-only, seed its reserve, add it to the
/// bundle) and wire the Bell once. It can never withdraw, reprice, remove, or touch a payout.
/// `treasury` is immutable. No owner, no pause, no upgrade.
contract BundleConverter is IConverter, StaleFeedGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct StockConfig {
        uint8 tokenDecimals;
        bool listed;
    }

    /// Sentinel `target` meaning "the default basket". Not a real token: `listStock` rejects it, so it
    /// can never collide with a payout stock. Exposed as a constant so the Bell's `defaultPayout` and
    /// the frontend can address the bundle without a per-deploy lookup.
    address public constant BUNDLE = address(0xB0B1);

    IERC20 public immutable base; // the Bell's reward token (USDG); pulled in convert, never held
    uint8 public immutable baseDecimals;
    address public immutable bankroll; // add-only registrar/seeder
    address public immutable treasury; // receives the base proceeds for reserve replenishment
    uint256 public immutable spreadBps; // protective haircut off oracle-fair output (0 = full value)

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_SPREAD_BPS = 500; // 5% ceiling on the config

    mapping(address => StockConfig) public stocks;
    address[] private _bundle; // basket members (each a listed stock); equal-parts split
    address public bell; // the sole `convert` caller, wired once post-deploy via initBell

    event StockListed(address indexed token, address feed);
    event ReserveSeeded(address indexed token, uint256 amount);
    event BundleMemberAdded(address indexed token, uint256 bundleSize);
    event BellWired(address indexed bell);
    event Converted(address indexed caller, address indexed target, uint256 amountIn, uint256 amountOut, address recipient);

    error BadConfig();
    error NotBankroll();
    error NotBell();
    error BellAlreadySet();
    error AlreadyListed();
    error NotListed();
    error AlreadyInBundle();
    error EmptyBundle();
    error NotInSession();
    error ZeroAmount();
    error DustAmount();

    constructor(
        IERC20 base_,
        AggregatorV3Interface baseFeed_,
        AggregatorV3Interface sequencerUptimeFeed_,
        address bankroll_,
        address treasury_,
        uint256 spreadBps_
    ) StaleFeedGuard(sequencerUptimeFeed_) {
        if (
            address(base_) == address(0) || address(baseFeed_) == address(0) || bankroll_ == address(0)
                || treasury_ == address(0) || spreadBps_ > MAX_SPREAD_BPS
        ) revert BadConfig();
        base = base_;
        baseDecimals = IERC20Metadata(address(base_)).decimals();
        bankroll = bankroll_;
        treasury = treasury_;
        spreadBps = spreadBps_;

        // Base priced through the same guard machinery (USDG/USD is a 24/7 crypto-style feed; the
        // session flag it returns is ignored for the base leg, exactly as in StockConverter/Cases).
        uint8 bfd = baseFeed_.decimals();
        if (bfd > 18) revert BadConfig(); // normalization assumes <= 18 (Chainlink uses 8)
        _setFeed(address(base_), baseFeed_, FEED_HEARTBEAT + STALENESS_GRACE, bfd);
    }

    // ---------------------------------------------------------------- views

    function isSupported(address token) external view returns (bool) {
        if (token == BUNDLE) return _bundle.length != 0;
        return stocks[token].listed;
    }

    function bundleSize() external view returns (uint256) {
        return _bundle.length;
    }

    function bundleAt(uint256 i) external view returns (address) {
        return _bundle[i];
    }

    /// The stock reserve currently backing payouts of `token`.
    function reserveOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ---------------------------------------------------------------- bankroll (add-only)

    /// Append-only: list a stock as a payout target with its Chainlink feed. Immutable once listed, so
    /// a stock members already opted into can't have its feed swapped underneath them.
    function listStock(address token, AggregatorV3Interface feed) external nonReentrant {
        if (msg.sender != bankroll) revert NotBankroll();
        if (token == address(0) || address(feed) == address(0) || token == address(base) || token == BUNDLE) {
            revert BadConfig();
        }
        if (stocks[token].listed) revert AlreadyListed();
        uint8 fd = feed.decimals();
        uint8 td = IERC20Metadata(token).decimals();
        if (fd > 18 || td > 18) revert BadConfig(); // normalization assumes <= 18
        stocks[token] = StockConfig(td, true);
        _setFeed(token, feed, FEED_HEARTBEAT + STALENESS_GRACE, fd);
        emit StockListed(token, address(feed));
    }

    /// Seed the payout reserve for a listed stock. Pulls stock from the bankroll; add-only, no
    /// withdrawal path ever.
    function seedReserve(address token, uint256 amount) external nonReentrant {
        if (msg.sender != bankroll) revert NotBankroll();
        if (!stocks[token].listed) revert NotListed();
        if (amount == 0) revert BadConfig();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveSeeded(token, amount);
    }

    /// Add a listed stock to the default basket (append-only). The bundle pays equal parts across its
    /// members, so adding a member changes the split for future payouts only.
    function addBundleMember(address token) external nonReentrant {
        if (msg.sender != bankroll) revert NotBankroll();
        if (!stocks[token].listed) revert NotListed();
        uint256 n = _bundle.length;
        for (uint256 i = 0; i < n; i++) {
            if (_bundle[i] == token) revert AlreadyInBundle();
        }
        _bundle.push(token);
        emit BundleMemberAdded(token, n + 1);
    }

    /// Wire the Bell as the ONLY caller of `convert` — one-shot. The Bell takes the converter in its
    /// own constructor, so the converter can't take the Bell as a constructor arg; this closes the loop
    /// after both exist. Until it's set, `convert` reverts for everyone, so the reserve is untouchable
    /// before it's wired. Bankroll-gated and immutable once set.
    function initBell(address bell_) external {
        if (msg.sender != bankroll) revert NotBankroll();
        if (bell != address(0)) revert BellAlreadySet();
        if (bell_ == address(0) || bell_.code.length == 0) revert BadConfig();
        bell = bell_;
        emit BellWired(bell_);
    }

    // ---------------------------------------------------------------- convert (the claim edge)

    /// Pull `amountIn` base from the caller (the Bell), deliver oracle-fair stock from the reserve
    /// straight to `recipient` (the Seat's Vault), and forward the base proceeds to the treasury.
    /// Reverts (never under-delivers) if the equity session is closed, a feed fails any StaleFeedGuard
    /// check, or the reserve can't cover — the Bell catches the revert and pays base instead.
    ///
    /// For a single stock `amountOut` is the stock delivered; for BUNDLE it is `amountIn` (the base
    /// converted), since a basket has no single output unit.
    function convert(uint256 amountIn, address target, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        // The Bell is the only legitimate caller: the reserve is not a public redeem-at-oracle desk.
        if (msg.sender != bell) revert NotBell();
        if (amountIn == 0) revert ZeroAmount();
        base.safeTransferFrom(msg.sender, address(this), amountIn); // pulled once, never held (forwarded below)

        if (target == BUNDLE) {
            uint256 n = _bundle.length;
            if (n == 0) revert EmptyBundle();
            uint256 part = amountIn / n;
            if (part == 0) revert DustAmount(); // payout smaller than the basket size — fail open to base
            for (uint256 i = 0; i < n; i++) {
                // Last member sweeps the division remainder so the whole payout is converted, no dust.
                uint256 slice = i == n - 1 ? amountIn - part * (n - 1) : part;
                _payStock(_bundle[i], slice, recipient);
            }
            amountOut = amountIn;
        } else {
            amountOut = _payStock(target, amountIn, recipient);
        }

        // No base at rest: hand the proceeds to the treasury (ops re-seed the stock reserve from it).
        base.safeTransfer(treasury, amountIn);
        emit Converted(msg.sender, target, amountIn, amountOut, recipient);
    }

    // ---------------------------------------------------------------- internals

    /// Deliver `baseAmt` worth of `token` (oracle-fair, minus the configured spread) from the reserve
    /// to `recipient`. Reverts off-session, on a bad feed, or if the reserve can't cover.
    function _payStock(address token, uint256 baseAmt, address recipient) internal returns (uint256 out) {
        StockConfig memory cfg = stocks[token];
        if (!cfg.listed) revert NotListed();
        out = _fairOut(baseAmt, token, cfg.tokenDecimals);
        if (out == 0) revert DustAmount();
        IERC20(token).safeTransfer(recipient, out); // reverts if the reserve is short → Bell pays base
    }

    /// Oracle-fair stock output for `amountIn` base. Both legs go through StaleFeedGuard (silent feeds,
    /// incomplete rounds, holiday gaps all revert); the stock leg additionally requires a live US
    /// session. Normalization is EsseyCases' sell-back math, inverted (base in -> stock out).
    function _fairOut(uint256 amountIn, address token, uint8 tgtDecimals) internal view returns (uint256) {
        (uint256 basePx, uint8 baseFeedDec,) = priceOf(address(base));
        (uint256 stockPx, uint8 stockFeedDec, bool inSession) = priceOf(token);
        if (!inSession) revert NotInSession();

        // usd = in * basePx / 10^baseDec (1e18); out = usd * 10^tgtDec / stockPx.
        uint256 usdValue18 = (amountIn * (basePx * 10 ** (18 - baseFeedDec))) / 10 ** baseDecimals;
        uint256 fairOut = (usdValue18 * 10 ** tgtDecimals) / (stockPx * 10 ** (18 - stockFeedDec));
        return spreadBps == 0 ? fairOut : (fairOut * (BPS - spreadBps)) / BPS;
    }
}
