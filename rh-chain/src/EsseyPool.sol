// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EsseyMarkets} from "./EsseyMarkets.sol";
import {CollateralReconciler} from "./CollateralReconciler.sol";
import {Note} from "./market/Note.sol";

/// The one thing the pool needs to know about a Bell: what token its pot counts. A minimal interface
/// (rather than importing the market layer) keeps the lending core's dependency arrow pointing the
/// right way — the game sits on the engine, never the reverse.
interface IRewardSink {
    function reward() external view returns (IERC20);
}

/// Lending pool: USDG in from lenders, Stock Tokens in as collateral, USDG out as loans.
///
/// The accrual and share maths are ported from the Sui implementation, which is the one part of
/// that codebase six adversarial audit rounds never landed a confirmed finding against. The
/// audit-derived invariants are carried over deliberately, each marked with the finding that
/// taught it — they were learned by finding real holes, not by reasoning ahead of time:
///
///   F5  repay accepts >= owed and RETURNS THE CHANGE. The Sui version demanded exact equality
///       against a debt that grows every second, which made repayment a race the borrower could
///       lose. Do not reintroduce it.
///   F3  liquidation seizes only what the debt plus bonus justifies and REFUNDS THE SURPLUS.
///       Seizing 100% punished a borrower 1bp underwater.
///   R3  positions are bound to their pool; there is exactly one pool per deployment here, so the
///       binding is structural rather than a stored id.
///   R5  exposure is released on close, exactly once. On Sui this leaked and bricked borrowing.
///   R6  and it is released in ONE place, because two release paths double-released.
///   R2  rate parameters are bounded and the maths saturates rather than trapping funds.
///
/// Shares are an ERC-20 so lenders can hold and transfer their claim.
contract EsseyPool is ERC4626, ReentrancyGuard, CollateralReconciler {
    using SafeERC20 for IERC20;

    error MarketClosed(address token);
    error LiquidationNotAllowed(address token);
    error NotBorrower();
    error NoDebt();
    error Undercollateralised(uint256 requested, uint256 max);
    error PositionHealthy();
    error ExceedsMarketCap(uint256 would, uint256 cap);
    error ExceedsPositionCap(uint256 debt, uint256 limit);
    error InsufficientLiquidity(uint256 want, uint256 have);
    error ZeroAmount();
    error UseFullRepay(uint256 amount, uint256 owed);
    error BadCurve();
    error BadSink();
    error AssetDecimalsMismatch();
    error NotAdmin();
    error NotResolver();
    error NotActivePool();
    error NotInsolvent(uint256 value, uint256 owed);
    error RecoveredExceedsOwed(uint256 recovered, uint256 owed);
    error RecoveredBelowFloor(uint256 recovered, uint256 floor);
    error DebtOutstanding(uint256 id);
    error NothingToClaim(uint256 id);

    event Borrowed(uint256 indexed id, address indexed borrower, address indexed token, uint256 collateral, uint256 debt);
    event BorrowedMore(uint256 indexed id, address indexed borrower, uint256 drawn, uint256 newDebt);
    event Repaid(uint256 indexed id, uint256 paid, uint256 collateralReturned);
    event CollateralEscrowed(uint256 indexed id, address indexed holder, uint256 amount);
    event CollateralClaimed(uint256 indexed id, address indexed to, uint256 amount);
    event RepaidPartial(uint256 indexed id, address indexed payer, uint256 paid, uint256 remainingDebt);
    event CollateralAdded(uint256 indexed id, address indexed payer, uint256 added, uint256 newCollateralRaw);
    event CollateralRemoved(uint256 indexed id, address indexed to, uint256 removed, uint256 newCollateralRaw);
    event Liquidated(uint256 indexed id, address liquidator, uint256 repaid, uint256 seized, uint256 refunded);
    event WrittenOff(uint256 indexed id, uint256 owed, uint256 recovered, uint256 fromReserves, uint256 lenderLoss, uint256 collateralSwept);
    event ReservesSkimmed(address indexed caller, uint256 toBell, uint256 toTreasury);

    /// The borrower is NOT stored: it is whoever holds the position's Note (an ERC-721 minted at
    /// borrow, burned at close). Repay authority, returned collateral, and liquidation surplus all
    /// follow `note.ownerOf(id)` at execution time, making positions transferable bearer instruments.
    struct Position {
        address token;
        uint256 collateralRaw;
        uint256 principal;
        uint256 indexSnapshot; // borrow index at open (debt growth)
        uint256 collIndexSnapshot; // collateral survival index at open (burn sharing — fix #2)
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    /// Ceiling on the SUM of curve legs. borrow_rate returns base + slope1 + slope2 at the top of
    /// the curve, so bounding the legs individually would permit 3x this (the R2-2 lesson).
    uint256 public constant MAX_RATE_BPS = 100_000; // 1000% APR

    EsseyMarkets public immutable markets;
    /// Constructor caller (admin EOA or the deploy script). Grants only the one-shot setNoteArt wiring
    /// — spent by Note.ArtAlreadySet the moment it is used — never money power.
    address public immutable deployer;
    /// AD-1: one pool serves exactly one collateral market. The former per-call `token` parameter is
    /// gone; every collateral path reads this binding instead.
    address public immutable collateralToken;
    /// The position deed collection, deployed and owned by this pool (mint on borrow, burn on close).
    Note public immutable note;

    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public borrowIndex = WAD;
    uint256 public lastAccrual;

    uint256 public baseBps;
    uint256 public slope1Bps;
    uint256 public slope2Bps;
    uint256 public kinkBps = 8_000;
    uint256 public reserveBps;

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) public positions;
    /// Borrowed principal per collateral token, against EsseyMarkets' per-market cap.
    mapping(address => uint256) public marketBorrows;

    /// Loan-interest routing — the third Bell engine, and the durable one: it pays as long as anyone
    /// is borrowing, independent of NFT volume. `bellShareBps` of every skimmed reserve goes to the
    /// Bell (a plain transfer of the pool asset, which the constructor proves IS the Bell's reward
    /// token, so it lands in the pot); the remainder goes to the reserve treasury. Lender yield is
    /// untouched by construction: `totalAssets` already excludes reserves, so a skim moves cash and
    /// `totalReserves` down in lockstep and the share price cannot move.
    address public immutable bellSink; // address(0) = no Bell wired (pre-market-layer deploys): all to treasury
    address public immutable reserveTreasury;
    uint256 public immutable bellShareBps;

    /// Per-pool naming, one struct rather than four loose strings: fifteen constructor arguments is
    /// past what solc can stack-allocate without via-ir, and via-ir for one constructor is not worth
    /// changing every contract's codegen.
    struct Identity {
        string shareName;
        string shareSymbol;
        string noteName;
        string noteSymbol;
    }

    constructor(
        IERC20 asset_,
        address collateralToken_,
        EsseyMarkets markets_,
        uint256 base_,
        uint256 s1_,
        uint256 s2_,
        uint256 reserve_,
        address bellSink_,
        address reserveTreasury_,
        uint256 bellShareBps_,
        Identity memory identity_
    ) ERC20(identity_.shareName, identity_.shareSymbol) ERC4626(IERC20(address(asset_))) {
        if (base_ + s1_ + s2_ > MAX_RATE_BPS || reserve_ > BPS) revert BadCurve();
        if (reserveTreasury_ == address(0) || bellShareBps_ > BPS) revert BadSink();
        // Deployment-coherence guard (the Exchange's lesson made a rule): if a Bell is wired, this
        // pool's asset must BE its reward token, or the skim would send funds the Bell never counts.
        if (bellSink_ != address(0) && address(IRewardSink(bellSink_).reward()) != address(asset_)) {
            revert BadSink();
        }
        // `markets.assetDecimals` is the third term of collateralValue's normalization (alongside the
        // collateral + feed decimals, which ARE cross-checked at propose/commit). Cross-check it against the
        // borrow asset's real decimals() here, so a mis-set value — e.g. 18 instead of mainnet USDG's 6 —
        // cannot reintroduce the 1e12 LTV over-valuation. Impossible-by-construction, matching fix #3.
        if (markets_.assetDecimals() != IERC20Metadata(address(asset_)).decimals()) revert AssetDecimalsMismatch();
        note = new Note(identity_.noteName, identity_.noteSymbol); // binds itself to this pool as its only minter/burner
        deployer = msg.sender;
        collateralToken = collateralToken_;
        markets = markets_;
        baseBps = base_;
        slope1Bps = s1_;
        slope2Bps = s2_;
        reserveBps = reserve_;
        bellSink = bellSink_;
        reserveTreasury = reserveTreasury_;
        bellShareBps = bellShareBps_;
        lastAccrual = block.timestamp;
    }

    /// The one-shot wiring seam: Note.setArt only accepts its pool, so the deploy script (as
    /// admin or deployer, same tx as the deploy) routes through here. Note's own guards make it
    /// once-only and contract-only.
    function setNoteArt(address art_) external {
        if (msg.sender != markets.admin() && msg.sender != deployer) revert NotAdmin();
        note.setArt(art_);
    }

    // ---------------------------------------------------------------- accrual

    /// Utilization over LENDABLE supply: protocol reserves are cash that was never lendable, so the
    /// skimmable part is excluded from the denominator. Without this, the rate borrowers pay would be
    /// a function of skim-keeper diligence — suppressed while reserves idle in the pool, then jumping
    /// discontinuously the moment anyone skims (audit F-1; the Compound-lineage lesson).
    function utilizationBps() public view returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 skimmable = totalReserves > cash ? cash : totalReserves;
        uint256 denom = (cash - skimmable) + totalBorrows;
        if (denom == 0) return 0;
        return (totalBorrows * BPS) / denom;
    }

    function borrowRateBps() public view returns (uint256) {
        uint256 u = utilizationBps();
        if (u <= kinkBps) return baseBps + (slope1Bps * u) / kinkBps;
        uint256 excess = u - kinkBps;
        uint256 span = BPS - kinkBps;
        return baseBps + slope1Bps + (slope2Bps * excess) / span;
    }

    /// Interest accrual. Saturates rather than reverting: an aborting cast here would freeze
    /// repayment and withdrawal for everyone, turning an accounting problem into a total loss
    /// (the R2-2 lesson, carried over).
    ///
    /// PAUSE-AWARE. A Robinhood token pause blocks transfers, so a borrower physically cannot
    /// repay. Charging interest across that window bills them for time in which repayment was
    /// impossible — and it is the issuer's pause, not theirs. `accrueFor` skips paused intervals.
    function accrue() public {
        (uint256 num, uint256 denom) = _growth();
        lastAccrual = block.timestamp;
        if (num == denom) return;

        // Guard the index multiply: borrowIndex is monotonic and never rebased, so at a sustained
        // maximum rate it would eventually overflow. Stop compounding rather than trap funds.
        if (borrowIndex <= type(uint256).max / num) {
            borrowIndex = (borrowIndex * num) / denom;
        }
        uint256 prev = totalBorrows;
        uint256 scaled = (prev * num) / denom;
        totalBorrows = scaled;
        uint256 interest = scaled - prev;
        // LOW-4, accepted with its threshold recorded rather than left as an oversight: `scaled` is
        // raw 6-decimal, so it truncates to zero below totalBorrows * rate * dt < BPS * SECONDS_PER_YEAR
        // — about $630 of book at 5% with dt = 1. Under that, a per-second accrue advances borrowIndex
        // (WAD-scaled) while the aggregate and the reserve cut stay flat. The cost is the reserve cut
        // on a dust book, griefable only by paying gas. Not worth a WAD-scaled aggregate.
        totalReserves += (interest * reserveBps) / BPS;
    }

    /// The compounding factor for the elapsed interval as (num, denom); num == denom means nothing
    /// accrues. ONE place computes it, so `accrue()` and the 4626 max* views can never disagree
    /// about what the next accrual will do.
    ///
    /// Only a BORROW-ASSET pause suspends the clock. Every repay and liquidate transfers the borrow
    /// asset, so its pause is the one event that blocks EVERY position from closing — the sole case
    /// where forgiving interest pool-wide is correct. A COLLATERAL-token pause blocks only that
    /// token's positions, not everyone's, so it must NOT forgive interest for the whole pool:
    /// watching collateral tokens (the previous behaviour) let an unrelated token's pause hand every
    /// borrower a free loan (fix #5). Accepted residual: a borrower whose collateral is paused still
    /// accrues during the freeze. That is a cost now, not a trap — repay() closes under a collateral
    /// pause and escrows the collateral (MED-1), so the borrower can always stop the clock.
    function _growth() internal view returns (uint256 num, uint256 denom) {
        denom = BPS * SECONDS_PER_YEAR;
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0 || totalBorrows == 0 || _borrowAssetPaused()) return (denom, denom);
        return (denom + borrowRateBps() * dt, denom);
    }

    /// `totalAssets()` as withdraw/redeem will see it — they accrue first, so a max* computed
    /// against today's price is computed against the wrong one.
    function _accruedAssets() internal view returns (uint256) {
        (uint256 num, uint256 denom) = _growth();
        uint256 borrows_ = (totalBorrows * num) / denom;
        uint256 reserves_ = totalReserves + ((borrows_ - totalBorrows) * reserveBps) / BPS;
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + borrows_;
        return gross > reserves_ ? gross - reserves_ : 0;
    }

    /// Does the BORROW ASSET report itself paused? Its pause blocks every repayment and liquidation, so
    /// accrual is suspended while it holds (see accrue). No admin-set watch list: the one token that
    /// matters is fixed (`asset()`), which also removes the admin surface the list carried.
    ///
    /// Decoded as a RAW WORD, never as `bool`: abi.decode(_, (bool)) reverts Panic(0x21) on any 32-byte
    /// word other than 0/1, and because this runs inside accrue()'s own frame that panic would bubble up
    /// and brick EVERY entry point — including liquidation (fix #1). A nonzero word is treated as paused
    /// (fail-safe: suspend rather than revert); a missing/short/reverting `paused()` is treated as
    /// not-paused. Gas-capped so a misbehaving asset can't grief accrue().
    function _borrowAssetPaused() internal view returns (bool) {
        (bool ok, bytes memory ret) = asset().staticcall{gas: 50_000}(abi.encodeWithSignature("paused()"));
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) != 0;
    }

    function debtOf(uint256 id) public view returns (uint256) {
        Position memory p = positions[id];
        if (p.principal == 0) return 0;
        return (p.principal * borrowIndex) / p.indexSnapshot;
    }

    // ---------------------------------------------------------------- lenders

    /// Lenders' claim: cash + outstanding borrows − the protocol's accrued cut.
    function totalAssets() public view override returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 gross = cash + totalBorrows;
        return gross > totalReserves ? gross - totalReserves : 0;
    }

    /// Virtual-share offset: the standard ERC-4626 inflation-attack mitigation.
    ///
    /// The hand-rolled version this replaced had none, and was exploitable exactly as the
    /// textbook describes: deposit 1 wei, donate directly to the pool to inflate the share price,
    /// and the next depositor's shares round to ZERO while the attacker redeems everything.
    /// Confirmed by PoC before this rewrite. OZ's offset makes the donation cost grow by 10^6 per
    /// unit of rounding stolen, which is what removes the attack rather than merely narrowing it.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// Accrue before any share-price-sensitive operation, so deposits and withdrawals price
    /// against current debt rather than a stale index.
    function _deposit(address caller, address receiver, uint256 assets_, uint256 shares)
        internal
        override
        nonReentrant
    {
        accrue();
        super._deposit(caller, receiver, assets_, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets_, uint256 shares)
        internal
        override
        nonReentrant
    {
        accrue();
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        if (assets_ > cash) revert InsufficientLiquidity(assets_, cash);
        super._withdraw(caller, receiver, owner_, assets_, shares);
    }

    /// Borrow-path fix #4: accrue BEFORE the share price is computed. OZ's public deposit/mint/withdraw/
    /// redeem call previewX() — which reads totalAssets() — BEFORE _deposit/_withdraw, where accrual used
    /// to happen. So shares were priced against stale, pre-interest totalAssets: a depositor could buy
    /// shares cheap and let the pending interest book into value in the same tx (deposit -> accrue ->
    /// redeem, flash-loanable), skimming interest owed to existing lenders. Accruing in the public entry
    /// point makes the preview see current debt. The accrue() still inside _deposit/_withdraw is then a
    /// dt==0 no-op, kept as defense-in-depth and because it carries the nonReentrant guard.
    function deposit(uint256 assets_, address receiver) public override returns (uint256) {
        accrue();
        return super.deposit(assets_, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        accrue();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets_, address receiver, address owner_) public override returns (uint256) {
        accrue();
        return super.withdraw(assets_, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override returns (uint256) {
        accrue();
        return super.redeem(shares, receiver, owner_);
    }

    /// LOW-1. `_withdraw` enforces a cash constraint OZ's unconstrained max* know nothing about, so
    /// both advertised more than the pool could pay and reverted when handed straight back (measured:
    /// cash 148355994889 vs maxWithdraw 150000000000). A human retries smaller; a 4626 router does not.
    ///
    /// Both clamp at cash and price against `_accruedAssets`, because withdraw/redeem accrue BEFORE
    /// previewing: shares sized at today's cheaper price redeem for more assets than the cash on hand.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 owned = _accruedConvertToAssets(balanceOf(owner_));
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        return owned < cash ? owned : cash;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 shares = balanceOf(owner_);
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 affordable = _accruedConvertToShares(cash);
        return shares < affordable ? shares : affordable;
    }

    /// OZ's virtual-share conversions, evaluated against the POST-accrual assets. Floor in both
    /// directions: the max* family must never round up into a revert.
    function _accruedConvertToAssets(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, _accruedAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    /// Floor, and the Ceil form is BEHAVIOURALLY equivalent here — but only because of the offset, so
    /// the condition is written down rather than left to be rediscovered (G-LEND R2 ruling 2).
    ///
    /// Ceil returns one more share whenever the division is inexact, and that share buys one more
    /// asset unit, landing maxRedeem's preview EXACTLY on `cash` instead of one short (measured:
    /// 144078231300 vs 144078231299). It never lands PAST it, so `_withdraw`'s cash constraint holds
    /// and no call reverts. That is true while one share is worth at most one asset unit —
    /// `_accruedAssets() + 1 <= totalSupply() + 10 ** _decimalsOffset()` — which the offset of 6
    /// gives 1e6x of headroom on. AT OFFSET 0 THE EQUIVALENCE FAILS: Ceil overshoots `cash` and
    /// `_withdraw` reverts, reintroducing the un-redeemable maxRedeem the max* rewrite removed.
    /// Change `_decimalsOffset` and this stops being a free choice.
    function _accruedConvertToShares(uint256 assets_) internal view returns (uint256) {
        return Math.mulDiv(assets_, totalSupply() + 10 ** _decimalsOffset(), _accruedAssets() + 1, Math.Rounding.Floor);
    }

    // ---------------------------------------------------------------- reserves -> the Bell

    /// Route accrued protocol reserves: `bellShareBps` to the Bell's pot, the rest to the reserve
    /// treasury. Permissionless, like ringing the Bell itself — the split is immutable, so there is
    /// no discretion for a caller to abuse, only a chore anyone may do.
    ///
    /// Bounded by cash: reserves are an accounting claim on cash + borrows, and only the cash part
    /// can move today. Skimming never touches lender value (`totalAssets` excludes reserves — cash
    /// and `totalReserves` fall in lockstep), and never moves the rate curve (`utilizationBps`
    /// already excludes the skimmable part). Two accepted notes from the audit: a skim can race a
    /// withdrawal or borrow for the same idle cash — one-shot, gas-cost griefing at worst, the lender simply
    /// retries; and in a catastrophic issuer-burn of pool cash, reserves rank effectively senior to
    /// lender shares (skim takes cash while totalAssets floors at zero) — a priority-of-claims
    /// choice made explicit here rather than left implicit.
    function skimReserves() external nonReentrant returns (uint256 toBell, uint256 toTreasury) {
        accrue();
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 take = totalReserves > cash ? cash : totalReserves;
        if (take == 0) return (0, 0);
        totalReserves -= take;
        toBell = bellSink != address(0) ? (take * bellShareBps) / BPS : 0;
        toTreasury = take - toBell;
        if (toBell != 0) IERC20(asset()).safeTransfer(bellSink, toBell);
        if (toTreasury != 0) IERC20(asset()).safeTransfer(reserveTreasury, toTreasury);
        emit ReservesSkimmed(msg.sender, toBell, toTreasury);
    }

    // ---------------------------------------------------------------- borrowers

    function borrow(uint256 collateralRaw, uint256 debt) external nonReentrant returns (uint256 id) {
        address token = collateralToken; // local alias keeps the audited body byte-comparable
        markets.syncMultiplier(token); // stamp any corporate-action multiplier move before the desync gate
        if (!markets.canBorrow(token)) revert MarketClosed(token);
        // F1 (round 6): canBorrow is per-token, so after a same-token succession a RETIRED pool's
        // gate re-armed — doubling effective exposure against the shared cap. Only the registry's
        // one active pool opens NEW borrows; every wind-down path here stays ungated on this.
        if (markets.activePool(token) != address(this)) revert NotActivePool();
        accrue();

        // Reconcile BEFORE pulling, so `actual` excludes this fresh deposit: the index then reflects
        // only PRIOR burns, and _creditCollateral snapshots that already-lowered index — insulating
        // this new position from losses it wasn't present for (fix #2). The fresh collateral genuinely
        // exists, so we still never lend against a burned balance (the adminBurn hazard).
        _reconcile(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), collateralRaw);
        uint256 collSnap = _creditCollateral(token, collateralRaw);

        // A zero-debt position is not openable: repay reverts NotBorrower at principal 0 and
        // isUnderwater is false at zero, so nothing but claimCollateral could ever touch it.
        if (debt == 0) revert NoDebt();
        // A fresh position draws, adds to marketBorrows, and pulls cash all in the one amount `debt`.
        _gateNewDebt(token, collateralRaw, debt, debt, debt);

        marketBorrows[token] += debt;
        totalBorrows += debt;
        id = nextPositionId++;
        positions[id] = Position(token, collateralRaw, debt, borrowIndex, collSnap);
        note.mint(msg.sender, id); // the position deed — holder is the borrower from here on
        IERC20(asset()).safeTransfer(msg.sender, debt);
        emit Borrowed(id, msg.sender, token, collateralRaw, debt);
    }

    /// The debt-opening gate, shared by borrow and borrowMore (delete-don't-duplicate). Same order
    /// and error arguments as the inline gate it replaced in borrow: LTV first, then market cap,
    /// then the floating per-position limit, then available cash. `posDebt` is the position's FULL
    /// debt after the operation; `mbDelta` is what this adds to marketBorrows and `draw` is the cash
    /// pulled — all three equal `debt` on a fresh borrow, and diverge on a top-up (mbDelta folds the
    /// position's accrued interest, draw is only the newly-drawn amount).
    ///
    /// AD-2: the live cap is min(static, depth-oracle), and the per-position limit floats with it —
    /// a shrunken market bounds single positions by what the venue can absorb TODAY.
    function _gateNewDebt(address token, uint256 coll, uint256 posDebt, uint256 mbDelta, uint256 draw)
        internal
        view
    {
        uint256 max = markets.maxBorrow(token, coll);
        if (posDebt > max) revert Undercollateralised(posDebt, max);
        uint256 cap = markets.borrowCap(token);
        uint256 would = marketBorrows[token] + mbDelta;
        if (would > cap) revert ExceedsMarketCap(would, cap);
        uint256 posLimit = (cap * markets.market(token).maxPositionBps) / BPS;
        if (posDebt > posLimit) revert ExceedsPositionCap(posDebt, posLimit);
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        if (draw > cash) revert InsufficientLiquidity(draw, cash);
    }

    /// Grow an EXISTING position's debt against its EXISTING collateral — no new Note, same id. Runs
    /// the full debt-opening gate (canBorrow, activePool, LTV, cap, position cap, cash) on the new
    /// TOTAL debt, exactly as borrow does on a fresh one, so a top-up that would breach any gate
    /// reverts atomically. Bearer-position auth: only the current Note holder may draw against it.
    ///
    /// The rebase mirrors repayPartial in the additive direction — accrued interest is folded into
    /// principal at the current index. marketBorrows tracks Σ principal (the invariant _releaseDebt
    /// depends on), so it takes the FULL principal delta (interest fold + draw), not just the draw;
    /// the cap is therefore checked against that same delta. totalBorrows already carries the accrued
    /// interest via accrue(), so it rises by only the newly-drawn amount.
    function borrowMore(uint256 id, uint256 additionalDebt) external nonReentrant {
        if (additionalDebt == 0) revert ZeroAmount();
        Position storage p = positions[id];
        if (p.principal == 0) revert NotBorrower();
        if (note.ownerOf(id) != msg.sender) revert NotBorrower();
        address token = p.token;
        markets.syncMultiplier(token); // stamp any corporate-action multiplier move before the desync gate
        if (!markets.canBorrow(token)) revert MarketClosed(token);
        if (markets.activePool(token) != address(this)) revert NotActivePool();
        accrue();

        _reconcile(token);
        uint256 eff = _effectiveCollateral(token, p.collateralRaw, p.collIndexSnapshot);
        uint256 oldPrincipal = p.principal;
        uint256 newPrincipal = debtOf(id) + additionalDebt; // owed at the current index, plus the draw
        _gateNewDebt(token, eff, newPrincipal, newPrincipal - oldPrincipal, additionalDebt);

        marketBorrows[token] += newPrincipal - oldPrincipal;
        totalBorrows += additionalDebt;
        p.principal = newPrincipal;
        p.indexSnapshot = borrowIndex;
        IERC20(asset()).safeTransfer(msg.sender, additionalDebt);
        emit BorrowedMore(id, msg.sender, additionalDebt, newPrincipal);
    }

    /// Repay. Accepts `amount >= owed` and refunds the difference.
    ///
    /// Deliberately NOT exact-equality (F5). Debt grows every second, so demanding an exact figure
    /// makes repayment a race between the borrower's transaction and the clock — one they can lose
    /// through no fault of their own.
    function repay(uint256 id, uint256 amount) external nonReentrant {
        accrue();
        Position memory p = positions[id];
        // A closed position is deleted (principal 0) and its Note burned; there is no borrower to
        // authorise. Same NotBorrower the pre-Note pool threw via its borrower==address(0) check.
        if (p.principal == 0) revert NotBorrower();
        // The borrower is whoever holds the Note NOW — positions are transferable bearer deeds.
        if (note.ownerOf(id) != msg.sender) revert NotBorrower();
        uint256 owed = debtOf(id);
        if (amount < owed) revert Undercollateralised(amount, owed);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), owed);
        // Reconcile BEFORE closing. _closePosition debits recordedRaw, so reconciling afterwards
        // compares a zeroed ledger against the surviving balance and silently reports no
        // shortfall — the adminBurn would vanish from the accounting entirely.
        _reconcile(p.token);
        // Pro-rata against what survives, computed BEFORE the ledger is debited (the nominal
        // total is the denominator). This is what stops one borrower being made whole out of
        // another's collateral after an adminBurn.
        uint256 give = _effectiveCollateral(p.token, p.collateralRaw, p.collIndexSnapshot);
        // Dust-guard: floored per-position entitlements can sum a few wei above the reconcile-floored
        // total, so the LAST closer in a freshly-burned cohort could be owed ~1 wei more than the pool
        // holds. Cap at the live balance — the pool can never transfer collateral it does not have; the
        // wei stays in the pool (safe direction).
        uint256 heldForRepay = IERC20(p.token).balanceOf(address(this));
        if (give > heldForRepay) give = heldForRepay;

        // The DEBT settles unconditionally; only the collateral return is allowed to fail.
        _releaseDebt(p, owed);
        positions[id].principal = 0;
        if (_tryReturnCollateral(p.token, msg.sender, give)) {
            _closePositionTail(id, p); // burns the Note; msg.sender was verified as its holder above
            emit Repaid(id, owed, give);
            return;
        }
        // MED-1. repay used to END in that transfer, so the issuer's PAUSER_ROLE (or a blocklist)
        // could pin a borrower inside a position that kept accruing: repay, addCollateral and
        // removeCollateral all reverted and only repayPartial survived, which cannot close. Now the
        // debt is gone the moment they pay, and the Note stays alive as the claim ticket. The
        // collateral stays on the books under this position's own index snapshot, so an adminBurn
        // during the freeze is shared exactly as it would have been before the repay.
        emit Repaid(id, owed, 0);
        emit CollateralEscrowed(id, msg.sender, give);
    }

    /// Collect the collateral of a position whose debt is settled but whose collateral could not be
    /// transferred at the time. Bearer auth like every other position path — whoever holds the Note
    /// — and permissionlessly retryable: no keeper, no privilege, no deadline. A still-failing
    /// transfer reverts the whole call, so nothing is consumed by a doomed attempt.
    function claimCollateral(uint256 id) external nonReentrant returns (uint256 given) {
        Position memory p = positions[id];
        if (p.token == address(0)) revert NothingToClaim(id);
        if (p.principal != 0) revert DebtOutstanding(id);
        if (note.ownerOf(id) != msg.sender) revert NotBorrower();

        _reconcile(p.token);
        given = _effectiveCollateral(p.token, p.collateralRaw, p.collIndexSnapshot);
        uint256 held = IERC20(p.token).balanceOf(address(this));
        if (given > held) given = held; // the repay/liquidate dust-cap
        _closePositionTail(id, p);
        IERC20(p.token).safeTransfer(msg.sender, given);
        emit CollateralClaimed(id, msg.sender, given);
    }

    /// Return collateral without letting its failure block the close. A revert, a `false` return and
    /// a short return all mean "not delivered" and route to the escrow.
    ///
    /// Decoded as a RAW WORD like _borrowAssetPaused, never abi.decode(_, (bool)), which panics on any
    /// word other than 0/1 and would bubble out of the repay it protects. The call precedes
    /// _closePositionTail, which looks like inverted CEI and is not: every entry point is nonReentrant,
    /// and the state visible during it IS the escrow state — a resting state, not a half-finished one.
    function _tryReturnCollateral(address token, address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        return ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) != 0);
    }

    /// Pay down part of the debt. PERMISSIONLESS and ungated (LivenessOracle.sol:109-111): paying
    /// someone's debt only helps them. Settling in full routes through repay(), which owns the close.
    function repayPartial(uint256 id, uint256 amount) external nonReentrant {
        accrue();
        Position storage p = positions[id];
        if (p.principal == 0) revert NoDebt();
        uint256 owed = debtOf(id);
        if (amount == 0) revert ZeroAmount();
        if (amount >= owed) revert UseFullRepay(amount, owed);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        // Rebase: remaining debt becomes the new principal at the current index. marketBorrows takes the
        // SIGNED delta and the rebased principal may sit past the market OR position cap — never revert
        // ExceedsMarketCap/ExceedsPositionCap here: both gate new borrows only.
        //
        // LOW-3, accepted. This call is permissionless, so a STRANGER paying 1 wei folds someone
        // else's accrued interest into principal when they choose, and marketBorrows takes the jump —
        // an outsider timing a figure that gates every new borrow. Accepted because the new figure is
        // the MORE honest one and the move is strictly toward LESS headroom: it can make the cap bind
        // sooner, never admit a borrow it should have refused. Folding interest in on accrue() instead
        // would desynchronise marketBorrows from _releaseDebt, which decrements by p.principal.
        uint256 oldPrincipal = p.principal;
        uint256 newPrincipal = owed - amount;
        p.principal = newPrincipal;
        p.indexSnapshot = borrowIndex;
        totalBorrows = totalBorrows > amount ? totalBorrows - amount : 0;
        uint256 mb = marketBorrows[p.token];
        if (newPrincipal >= oldPrincipal) {
            marketBorrows[p.token] = mb + (newPrincipal - oldPrincipal);
        } else {
            uint256 dec = oldPrincipal - newPrincipal;
            marketBorrows[p.token] = mb > dec ? mb - dec : 0;
        }
        emit RepaidPartial(id, msg.sender, amount, newPrincipal);
    }

    /// Top up collateral. PERMISSIONLESS and gated on NOTHING (liveness/session/enabled/desync):
    /// blocking a top-up in an outage causes the liquidation the gates prevent (LivenessOracle.sol:109-111).
    function addCollateral(uint256 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage p = positions[id];
        if (p.principal == 0) revert NoDebt();
        address token = p.token;
        // Reconcile BEFORE the transfer (like borrow): entitlement reflects prior burns only.
        _reconcile(token);
        uint256 eff = _effectiveCollateral(token, p.collateralRaw, p.collIndexSnapshot);
        _debitCollateral(token, p.collateralRaw, p.collIndexSnapshot);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 snap = _creditCollateral(token, eff + amount); // CollateralCohortWiped on a dead cohort
        p.collateralRaw = eff + amount;
        p.collIndexSnapshot = snap;
        emit CollateralAdded(id, msg.sender, amount, eff + amount);
    }

    /// Withdraw collateral from an existing position. Bearer-position auth (Note holder only). Adds
    /// no debt, so it is NOT market-cap gated; it IS health-gated — the position must remain within
    /// LTV AFTER removal, priced at the current feed (maxBorrow reverts on a stale price or a disabled
    /// market, both the safe direction). A position wanting all its collateral back closes via repay.
    ///
    /// GATED like borrowMore (syncMultiplier + canBorrow), because a withdrawal is a risk-INCREASING
    /// action — economically equivalent to a borrow against the freed collateral — so it takes the
    /// same new-risk gates. The earlier "a desync only reads collateral lower, so removal is stricter"
    /// note was FALSE: a corporate-action desync mis-prices ~2x in BOTH directions, so within the
    /// window the LTV check can read collateral ~2x HIGH and free ~2x what the true price permits,
    /// leaving the pool bad debt. Off-session/desync now revert MarketClosed; a borrower needing
    /// collateral back off-session full-repays instead. Actual de-risking (addCollateral, repay)
    /// stays ungated — only new risk takes the gates.
    function removeCollateral(uint256 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage p = positions[id];
        if (p.principal == 0) revert NoDebt();
        if (note.ownerOf(id) != msg.sender) revert NotBorrower();
        address token = p.token;
        markets.syncMultiplier(token); // stamp any corporate-action multiplier move before the desync gate
        if (!markets.canBorrow(token)) revert MarketClosed(token);
        accrue();

        // Reconcile BEFORE computing entitlement (like addCollateral): a prior burn must be reflected,
        // or the health check would price collateral the pool no longer holds.
        _reconcile(token);
        uint256 eff = _effectiveCollateral(token, p.collateralRaw, p.collIndexSnapshot);
        if (amount > eff) revert InsufficientLiquidity(amount, eff);
        uint256 remaining = eff - amount;
        uint256 max = markets.maxBorrow(token, remaining);
        uint256 owed = debtOf(id);
        if (owed > max) revert Undercollateralised(owed, max);

        _debitCollateral(token, p.collateralRaw, p.collIndexSnapshot);
        uint256 snap = _creditCollateral(token, remaining); // CollateralCohortWiped on a dead cohort
        p.collateralRaw = remaining;
        p.collIndexSnapshot = snap;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralRemoved(id, msg.sender, amount, remaining);
    }

    /// Liquidate an underwater position. Permissionless — the on-chain price and the liveness
    /// gate decide legitimacy, not a privileged role.
    ///
    /// Seizes only what the debt plus the market's bonus justifies and REFUNDS THE SURPLUS to the
    /// borrower (F3). Taking the whole position punished a borrower 1bp underwater.
    function liquidate(uint256 id) external nonReentrant {
        Position memory p = positions[id];
        if (p.principal == 0) revert NoDebt();
        markets.syncMultiplier(p.token); // stamp any corporate-action multiplier move before the desync gate
        if (!markets.canLiquidate(p.token)) revert LiquidationNotAllowed(p.token);
        accrue();

        _reconcile(p.token);
        // Health must be judged on collateral that STILL EXISTS. Using the stored figure made a
        // position whose collateral had been burned away read as healthy — permanently
        // unliquidatable while fully unsecured.
        uint256 effective = _effectiveCollateral(p.token, p.collateralRaw, p.collIndexSnapshot);
        // Dust-guard (see repay): cap at the live balance so seize + refund can never exceed what the
        // pool holds. Capping lower only ever makes a position read as MORE underwater — the safe direction.
        uint256 heldForLiq = IERC20(p.token).balanceOf(address(this));
        if (effective > heldForLiq) effective = heldForLiq;
        uint256 owed = debtOf(id);
        if (!markets.isUnderwater(p.token, effective, owed)) revert PositionHealthy();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), owed);
        _releaseDebt(p, owed);

        // Seize debt + bonus, valued at the live price, and never more than the position holds.
        uint256 bonusBps = markets.market(p.token).liqBonusBps;
        uint256 target = (owed * (BPS + bonusBps)) / BPS;
        uint256 seize = _rawWorth(p.token, target);
        uint256 available = effective;
        if (seize > available) seize = available;

        uint256 refund = available - seize;
        // Read the holder BEFORE the close path burns the Note — the surplus belongs to whoever
        // holds the position deed at liquidation time (F3, carried over to bearer semantics).
        address holder = note.ownerOf(id);

        // MED-1's escrow, applied to the lender's side (G-LEND R2 LOW-1). repay stopped reverting
        // under a frozen collateral token; liquidate did not, so the one path that manages risk died
        // exactly when the issuer froze the asset, while interest kept compounding.
        //
        // ONLY WHEN THE SEIZURE TAKES EVERYTHING, because an escrow has exactly one claimant and the
        // deed is the ticket. refund > 0 means two claimants, and rather than invent a second deed
        // the pool declines. That residual is precisely the not-at-risk band: refund > 0 requires
        // collateral worth more than 1.05x the debt, so the position is still over-collateralised and
        // waiting costs lenders nothing. Below it, seize == available and there is one claimant.
        if (refund == 0) {
            if (_tryReturnCollateral(p.token, msg.sender, seize)) {
                _closePositionTail(id, p);
                emit Liquidated(id, msg.sender, owed, seize, 0);
                return;
            }
            positions[id].principal = 0;
            // Re-issue the deed to the liquidator: they paid `owed` and the position is fully seized,
            // so the borrower has no residual claim. burn+mint rather than a new privileged transfer
            // on Note — both are already pool-only, and mint is callback-free (Note.sol:38-40).
            note.burn(id);
            note.mint(msg.sender, id);
            emit Liquidated(id, msg.sender, owed, 0, 0);
            emit CollateralEscrowed(id, msg.sender, seize);
            return;
        }
        _closePositionTail(id, p);
        IERC20(p.token).safeTransfer(msg.sender, seize);
        IERC20(p.token).safeTransfer(holder, refund);
        emit Liquidated(id, msg.sender, owed, seize, refund);
    }

    /// Recognize bad debt (AD-1 #2): the resolver settles a beyond-recovery position, paying in
    /// whatever it could recover and taking the residual collateral for off-chain workout. The
    /// unrecovered residual is absorbed by protocol reserves FIRST, then marked down pro-rata
    /// across this pool's lenders — taken when it happens, not queued for the last redeemer.
    ///
    /// "Beyond recovery" is strict: collateral wiped entirely (no price needed), or worth less
    /// than the debt at a price canLiquidate vouches for. A merely-underwater position reverts —
    /// that is the liquidator's job, at market, not the resolver's. The swept collateral is paid
    /// for at no less than its market value (RecoveredBelowFloor) — without the floor a resolver
    /// could pay 0 and sweep collateral worth ~owed (A-M1).
    ///
    /// Accepted (A-L1): reserves-first covers only UNSKIMMED reserves by construction —
    /// skimReserves is permissionless and race-able. Accepted (A-L2): loss-recognition latency
    /// between insolvency and the resolver's call is inherent to manual recognition and bounded
    /// per-market by isolation.
    function writeOff(uint256 id, uint256 recovered) external nonReentrant {
        address resolver_ = markets.resolver();
        if (msg.sender != resolver_) revert NotResolver();
        Position memory p = positions[id];
        if (p.principal == 0) revert NoDebt();
        accrue();
        markets.syncMultiplier(p.token);
        _reconcile(p.token);

        uint256 effective = _effectiveCollateral(p.token, p.collateralRaw, p.collIndexSnapshot);
        uint256 held = IERC20(p.token).balanceOf(address(this));
        if (effective > held) effective = held; // the liquidate/repay dust-cap
        uint256 owed = debtOf(id);
        uint256 floor;
        if (effective != 0) {
            if (!markets.canLiquidate(p.token)) revert LiquidationNotAllowed(p.token);
            (uint256 value,) = markets.collateralValue(p.token, effective);
            if (value >= owed) revert NotInsolvent(value, owed);
            floor = value; // the swept `effective` is worth this much — the resolver pays at least it
        }
        if (recovered > owed) revert RecoveredExceedsOwed(recovered, owed);
        if (recovered < floor) revert RecoveredBelowFloor(recovered, floor);

        IERC20(asset()).safeTransferFrom(resolver_, address(this), recovered);
        _releaseDebt(p, owed);
        uint256 residual = owed - recovered;
        uint256 fromReserves = totalReserves < residual ? totalReserves : residual;
        totalReserves -= fromReserves;
        // The escrow again (G-LEND R2 LOW-1), and it matters more here than at liquidate: write-off is
        // how a loss is RECOGNISED, and a frozen token used to block even a position whose collateral
        // was already burned to nothing — `effective == 0` still ended in a transfer the pause
        // reverted. One claimant by construction, so the deed carries the claim cleanly.
        if (!_tryReturnCollateral(p.token, resolver_, effective)) {
            positions[id].principal = 0;
            note.burn(id);
            note.mint(resolver_, id);
            emit WrittenOff(id, owed, recovered, fromReserves, residual - fromReserves, 0);
            emit CollateralEscrowed(id, resolver_, effective);
            return;
        }
        _closePositionTail(id, p);
        emit WrittenOff(id, owed, recovered, fromReserves, residual - fromReserves, effective);
    }

    /// Raw collateral units worth `value` in borrow-asset terms, at the live price and multiplier.
    function _rawWorth(address token, uint256 value) internal view returns (uint256) {
        (uint256 unitValue,) = markets.collateralValue(token, WAD);
        if (unitValue == 0) return 0;
        return (value * WAD) / unitValue;
    }

    /// Debt-side release, and the ONE place a position's exposure is released (R5/R6). Two release
    /// paths on Sui double-released and made the cap stop binding; there is exactly one here by
    /// construction. Separated from the collateral side so liquidate can settle the debt, compute
    /// the seizure against the still-intact ledger, and only then retire the position — and so
    /// repay can settle the debt whether or not the collateral can physically move (MED-1).
    function _releaseDebt(Position memory p, uint256 owed) internal {
        totalBorrows = totalBorrows > owed ? totalBorrows - owed : 0;
        uint256 mb = marketBorrows[p.token];
        marketBorrows[p.token] = mb > p.principal ? mb - p.principal : 0;
    }

    /// Collateral-side release. The ONE place a position leaves the books (R5/R6) — and therefore
    /// the one place its Note burns: a spent deed cannot exist, so nobody can be sold a claim on a
    /// position that already ended.
    function _closePositionTail(uint256 id, Position memory p) internal {
        _debitCollateral(p.token, p.collateralRaw, p.collIndexSnapshot);
        delete positions[id];
        note.burn(id);
    }
}
