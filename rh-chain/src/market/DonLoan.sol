// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Don} from "./Don.sol";
import {DonReserve} from "./DonReserve.sol";
import {Guarded} from "./Guarded.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// DonLoan — fixed-TERM borrowing against your Don, the proven NFT-desk mechanic rebuilt on Essey's
/// provable floor: the desk's revenue is banked the moment the loan is written — interest for the whole
/// term is charged UP FRONT (a discount note), plus an ETH origination fee (USD-priced by the ETH/USD
/// feed when wired, flat wei otherwise — the fee is the ONLY thing the feed prices).
///
/// THE TERM LOAN, FIXED-DRAW: `borrow(donId, term)` draws exactly `ltvBps` of the live floor — every
/// loan is a full draw against the value line, which tracks the rising floor. The term's interest is
/// priced on that same VALUE, not the principal: `prepaidInterest = floorPerDon * rateBps * term /
/// (BPS * YEAR)`, deducted from the disbursement (a discount note) and routed 70/30 (stock pot /
/// floor) IN THE BORROW TX. The borrower owes back exactly the principal, any time up to expiry — no
/// main-phase accrual bookkeeping, and NO REFUND on early repay: the prepaid interest bought the right
/// to hold the money for the term. The constructor invariant `rateBps * MAX_TERM / YEAR < ltvBps`
/// guarantees the fee can never swallow the draw. Past expiry the loan goes LATE: principal accrues
/// per-second at `penaltyRateBps` (2x the base rate at deploy) until repaid or liquidated.
///
/// WHY ESSEY-DENOMINATED: the proven NFT-desk mechanic lends the asset its floor is priced
/// in, with no external oracle — the protocol's own floor IS the price. Essey's Don floor is
/// `DonReserve.floorPerDon()` in $ESSEY, so the facility lends $ESSEY. Debt and collateral share one
/// unit, so LTV and liquidation need NO oracle, NO session gate, NO keeper — and solvency is provable
/// from two on-chain invariants alone: the floor never decreases (DonReserve is fund-only, pro-rata on
/// redeem) and every loan starts at <= 50% of it. A borrower who wants dollars swaps the borrowed
/// $ESSEY themselves.
///
/// LIEN, NOT ESCROW: the Don STAYS IN THE BORROWER'S WALLET under a transfer lock (`Don.liened`), so it
/// stays staked in the Bell and keeps earning stock dividends into its Vault while collateralized — a
/// real margin account. Escrow would fire the Bell's transfer hook and clear the tier; the lien doesn't.
/// Every exit (sale, AMM, reserve redemption) is blocked until the debt clears.
///
/// TWO LIQUIDATION TRIGGERS, both permissionless and capital-free: (a) the RATIO — debt above
/// `liqThresholdBps` of the LIVE floor (only late-phase accrual can push a loan there; during the term
/// debt is flat) — and (b) the CALENDAR — `expiry + defaultGraceSeconds` has passed, whatever the
/// ratio. Settlement is one waterfall either way: the facility seizes the liened Don, redeems it at
/// the DonReserve floor, tips the caller, routes late interest 70/30, restores principal to the pot,
/// and returns the SURPLUS TO THE BORROWER — a defaulter loses the Don and the late interest, not the
/// equity above the debt. WARNING to borrowers (surface in UI): the Don's Vault — with any unclaimed
/// dividends — travels with the redeemed Don and is forfeited too; service your loan.
///
/// THE FLYWHEEL: all interest — prepaid at borrow, late-phase on repay and on liquidation recovery —
/// is SPLIT `stockShareBps` (70%) to `feeSink`, the fee->stock router that buys Robinhood stock for
/// staked Dons, and the remainder (30%) to the DonReserve, raising the floor for every Don. Borrowing
/// activity visibly pays the room AND hardens everyone's collateral — the same 70/30 shape the AMM's
/// fees already follow.
///
/// PROVABLE SOLVENCY (dregg): every loan stores its canonical solvency tuple — (facility, borrower,
/// debt, floor, ltvBps, nonce), amounts in WHOLE ESSEY so they fit the circuit's 64-bit bounds — which
/// the dregg prover commits with Poseidon and proves `debt * 10000 <= floor * ltvBps` under the
/// existing Groth16 verifier. Debt is principal-or-more (never less), so the ceiled tuple can only
/// overstate risk. The circuit's collateral-type binding generalizes; no circuit change.
///
/// TRUST SURFACE: adminless over user funds. `treasury` may withdraw only IDLE funding (protocol seed
/// sitting unlent) — outstanding debt is owed to the facility and returns on repay; no role can touch a
/// borrower's collateral except through the public liquidation path.
contract DonLoan is ReentrancyGuard, Guarded {
    using SafeERC20 for IERC20;

    IERC20 public immutable essey;
    Don public immutable don;
    DonReserve public immutable reserve; // floor source, redemption sink for seizures, floor-share sink
    address public immutable feeSink; // stockShareBps of interest -> the fee->stock router (pays staked Dons)
    address public immutable treasury; // may reclaim idle (unlent) funding only

    uint256 public immutable ltvBps; // 5000 = borrow up to 50% of the floor
    uint256 public immutable liqThresholdBps; // 7000 = liquidatable once debt > 70% of the LIVE floor
    uint256 public immutable rateBps; // 1500 = 15% APR on the FLOOR VALUE, charged up front over the term
    uint256 public immutable penaltyRateBps; // 3000 = late-phase APR on principal past expiry (> rateBps)
    uint256 public immutable defaultGraceSeconds; // past expiry + this, liquidation opens whatever the ratio
    uint256 public immutable liqTipBps; // caller's cut of liquidation proceeds (e.g. 100 = 1%)
    uint256 public immutable stockShareBps; // 7000 = 70% of interest -> feeSink; remainder -> the floor

    /// The ETH origination fee — the second upfront-revenue leg — is USD-priced when the ETH/USD feed
    /// is wired, flat-wei otherwise. HARD BOUNDARY: this feed prices ONLY the fee. It must never
    /// appear anywhere near maxBorrow/debtOf/liquidation/loanTuple — the loan book stays entirely
    /// floor-priced and oracle-free, so a compromised feed can only misprice a capped toll, never a
    /// loan. 100% of the fee -> feeSink, the same proven ETH->USDG->Bell pipe the mint fees ride.
    AggregatorV3Interface public immutable ethUsdFeed; // address(0) = oracle mode off, flat-only
    uint8 public immutable feedDecimals;
    uint256 public originationFeeUsdCents; // treasury-tunable USD price, 1000 = $10.00; 0 = oracle mode off
    uint256 public originationFeeWei; // the flat FALLBACK (and the only price when no feed is wired)
    uint256 public constant MAX_ORIGINATION_FEE = 0.05 ether; // clamps BOTH modes — no config or feed can exceed it
    uint256 public constant MAX_ORIGINATION_FEE_USD_CENTS = 10_000; // $100
    uint256 internal constant FEED_MAX_AGE = 90_000; // ~25h: one heartbeat + grace, same budget as the fee router

    /// Term bounds: long enough that prepaid interest is real revenue, short enough that the calendar
    /// trigger (expiry + grace) keeps every loan on a bounded clock.
    uint256 public constant MIN_TERM = 7 days;
    uint256 public constant MAX_TERM = 365 days;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    /// Same risk discipline as EsseyMarkets: the liquidation threshold must sit a full 20pp above LTV.
    /// During the prepaid term debt is FLAT at principal (<= ltvBps of the origination floor), so only
    /// late-phase accrual can close the gap — and under the grace bounds below the calendar trigger
    /// always opens before the ratio can.
    uint256 internal constant MIN_RISK_GAP_BPS = 2_000;
    uint256 internal constant MAX_LIQ_THRESHOLD_BPS = 9_000;
    uint256 internal constant MAX_TIP_BPS = 500;
    /// Grace bounds: at least a week to cure a missed expiry, at most a quarter before the pot's
    /// capital can be recycled.
    uint256 internal constant MIN_GRACE = 7 days;
    uint256 internal constant MAX_GRACE = 90 days;

    struct Loan {
        address borrower;
        uint256 principal; // owed back in full — the term's interest was already collected at borrow
        uint256 lateAccrued; // late-phase interest checkpointed but unpaid
        uint64 expiry; // end of the prepaid term; the late phase starts here
        uint64 lateAccrual; // late-phase checkpoint; initialized to expiry, only moves once past it
        uint64 nonce; // this loan's slot in the dregg proof stream
    }

    mapping(uint256 => Loan) public loans; // donId => loan (one open loan per Don)
    uint256 public totalPrincipal; // sum of outstanding principals
    uint64 public loanNonce; // monotone loan counter (proof-tuple nonce)

    event Funded(address indexed from, uint256 amount);
    event Borrowed(
        uint256 indexed donId,
        address indexed borrower,
        uint256 amount,
        uint64 termSeconds,
        uint256 prepaidInterest,
        uint64 nonce
    );
    event Repaid(uint256 indexed donId, address indexed payer, uint256 interestPaid, uint256 principalPaid, bool closed);
    event Liquidated(
        uint256 indexed donId,
        address indexed caller,
        uint256 proceeds,
        uint256 debtRecovered,
        uint256 surplusToBorrower,
        uint256 tip
    );
    event IdleWithdrawn(address indexed to, uint256 amount);
    event OriginationFeeSet(uint256 wei_);
    event OriginationFeeUsdSet(uint256 cents);
    event OriginationPaid(uint256 indexed donId, uint256 fee);

    error BadConfig();
    error ZeroAmount();
    error BadTerm();
    error PrepaidExceedsPrincipal();
    error NotDonOwner();
    error LoanExists();
    error NoLoan();
    error NotLiquidatable(uint256 debt, uint256 threshold);
    error NotTreasury();
    error WrongFee();
    error FeeTooHigh();
    error FeeForwardFailed();
    error RefundFailed();

    /// One constructor argument — the config as a struct (the DonFeeRouter shape; fourteen loose
    /// params overflow the legacy pipeline's stack).
    struct Config {
        IERC20 essey;
        Don don;
        DonReserve reserve;
        address feeSink;
        address treasury;
        uint256 ltvBps;
        uint256 liqThresholdBps;
        uint256 rateBps;
        uint256 penaltyRateBps;
        uint256 defaultGraceSeconds;
        uint256 liqTipBps;
        uint256 stockShareBps;
        AggregatorV3Interface ethUsdFeed; // address(0) = flat-only origination fee
        address guardian;
    }

    constructor(Config memory c) Guarded(c.guardian) {
        if (
            address(c.essey) == address(0) || address(c.don) == address(0) || address(c.reserve) == address(0)
                || c.feeSink == address(0) || c.treasury == address(0) || c.ltvBps == 0
                || c.ltvBps + MIN_RISK_GAP_BPS > c.liqThresholdBps || c.liqThresholdBps > MAX_LIQ_THRESHOLD_BPS
                // The value-basis fee must never swallow the draw: the worst-case prepaid (a full
                // MAX_TERM at rateBps of the floor) has to stay strictly below ltvBps of that floor.
                || c.rateBps == 0 || (c.rateBps * MAX_TERM) / YEAR >= c.ltvBps
                || c.penaltyRateBps <= c.rateBps || c.penaltyRateBps > BPS
                || c.defaultGraceSeconds < MIN_GRACE || c.defaultGraceSeconds > MAX_GRACE
                || c.liqTipBps > MAX_TIP_BPS || c.stockShareBps > BPS
        ) revert BadConfig();
        // The reserve must actually be the floor of THIS Don — a mismatched pairing would let borrowing
        // against one collection be priced by another's reserve.
        if (address(c.reserve.don()) != address(c.don)) revert BadConfig();
        essey = c.essey;
        don = c.don;
        reserve = c.reserve;
        feeSink = c.feeSink;
        treasury = c.treasury;
        ltvBps = c.ltvBps;
        liqThresholdBps = c.liqThresholdBps;
        rateBps = c.rateBps;
        penaltyRateBps = c.penaltyRateBps;
        defaultGraceSeconds = c.defaultGraceSeconds;
        liqTipBps = c.liqTipBps;
        stockShareBps = c.stockShareBps;
        ethUsdFeed = c.ethUsdFeed;
        feedDecimals = address(c.ethUsdFeed) == address(0) ? 0 : c.ethUsdFeed.decimals();
    }

    // ---------------------------------------------------------------- views

    /// $ESSEY currently available to lend.
    function lendable() public view returns (uint256) {
        return essey.balanceOf(address(this));
    }

    /// The fixed draw every loan takes right now: half (ltvBps) of the live floor.
    function maxBorrow() public view returns (uint256) {
        return (reserve.floorPerDon() * ltvBps) / BPS;
    }

    /// What a term of `termSeconds` costs up front, priced on the LIVE FLOOR (the value basis): the
    /// interest deducted from the disbursement. The borrower still owes back the full draw.
    function prepaidInterest(uint256 termSeconds) public view returns (uint256) {
        return (reserve.floorPerDon() * rateBps * termSeconds) / (BPS * YEAR);
    }

    /// A loan's debt right now: exactly the principal until expiry (the term's interest was prepaid),
    /// then principal + late interest — simple (non-compounding), per second at `penaltyRateBps`.
    /// No interest ever refunds.
    function debtOf(uint256 donId) public view returns (uint256) {
        Loan storage l = loans[donId];
        if (l.borrower == address(0)) return 0;
        return l.principal + l.lateAccrued + _pendingLate(l);
    }

    /// The ETH owed at borrow, right now. USD mode when the feed is wired AND a USD price is set: the
    /// feed converts `originationFeeUsdCents` to wei, guarded by a self-contained staleness check —
    /// positive answer, updated within FEED_MAX_AGE, round complete. ANY failed check (or a reverting
    /// feed) falls back to the flat `originationFeeWei`: borrowing must never brick on a dead feed,
    /// and the worst a hostile feed can do is move a toll inside [flat-fallback, MAX_ORIGINATION_FEE].
    /// Both configs zero = free.
    function originationFee() public view returns (uint256) {
        uint256 cents = originationFeeUsdCents;
        if (address(ethUsdFeed) != address(0) && cents > 0) {
            try ethUsdFeed.latestRoundData() returns (
                uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
            ) {
                if (
                    answer > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= FEED_MAX_AGE
                        && answeredInRound >= roundId
                ) {
                    uint256 fee = (cents * 10 ** (18 + feedDecimals)) / (uint256(answer) * 100);
                    return fee > MAX_ORIGINATION_FEE ? MAX_ORIGINATION_FEE : fee;
                }
            } catch {}
        }
        return originationFeeWei;
    }

    /// Debt above this is liquidatable. Reads the LIVE floor, so funding the reserve heals loans.
    /// (The calendar trigger — expiry + grace — is independent of this and never heals.)
    function liquidationThreshold() public view returns (uint256) {
        return (reserve.floorPerDon() * liqThresholdBps) / BPS;
    }

    /// The canonical dregg solvency tuple for a loan, amounts in WHOLE ESSEY (fits the circuit's 64-bit
    /// debt/collateral bounds). The prover Poseidon-commits these fields and proves
    /// `debt * 10000 <= floor * ltvBps` under the deployed Groth16 verifier.
    function loanTuple(uint256 donId)
        external
        view
        returns (address facility, address borrower, uint64 debtWhole, uint64 floorWhole, uint16 ltv, uint64 nonce_)
    {
        Loan storage l = loans[donId];
        if (l.borrower == address(0)) revert NoLoan();
        return (
            address(this),
            l.borrower,
            // Debt rounds UP, floor rounds DOWN — both in the conservative direction, so the whole-token
            // tuple can only ever overstate risk to the prover, never understate it. Debt is
            // principal-or-more under the term model, so the tuple stays conservative.
            uint64((debtOf(donId) + 1e18 - 1) / 1e18),
            uint64(reserve.floorPerDon() / 1e18),
            uint16(ltvBps),
            l.nonce
        );
    }

    /// Late interest since the last late checkpoint. Zero for the whole prepaid term: the checkpoint
    /// starts AT expiry and only ever moves forward from there.
    function _pendingLate(Loan storage l) internal view returns (uint256) {
        if (block.timestamp <= l.lateAccrual) return 0;
        return (l.principal * penaltyRateBps * (block.timestamp - l.lateAccrual)) / (BPS * YEAR);
    }

    /// Route settled interest: `stockShareBps` to the feeSink (stock for staked Dons — borrowing pays
    /// the room), the remainder to the DonReserve (every Don's floor rises). Conservation is exact:
    /// the two legs always sum to `amount`.
    function _routeInterest(uint256 amount) internal {
        if (amount == 0) return;
        uint256 toStock = (amount * stockShareBps) / BPS;
        uint256 toFloor = amount - toStock;
        if (toStock > 0) essey.safeTransfer(feeSink, toStock);
        if (toFloor > 0) essey.safeTransfer(address(reserve), toFloor);
    }

    function _accrueLate(Loan storage l) internal {
        if (block.timestamp <= l.lateAccrual) return; // still inside the prepaid term
        l.lateAccrued += _pendingLate(l);
        l.lateAccrual = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- funding

    /// Add lending capital. Permissionless — the treasury seeds it; anyone may deepen it. (A plain
    /// transfer works identically: `lendable` reads the balance.)
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        essey.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// Tune the flat ETH origination fee — the fallback under a wired feed, the whole price without
    /// one (treasury = the multisig; capped). 0 = free borrowing (when USD mode is off too).
    function setOriginationFee(uint256 wei_) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (wei_ > MAX_ORIGINATION_FEE) revert FeeTooHigh();
        originationFeeWei = wei_;
        emit OriginationFeeSet(wei_);
    }

    /// Tune the USD origination price (treasury = the multisig; capped). Only takes effect while the
    /// feed is wired and healthy; 0 = USD mode off, flat fee governs.
    function setOriginationFeeUsdCents(uint256 cents) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (cents > MAX_ORIGINATION_FEE_USD_CENTS) revert FeeTooHigh();
        originationFeeUsdCents = cents;
        emit OriginationFeeUsdSet(cents);
    }

    /// Reclaim IDLE capital only. Outstanding principal has already left the balance, and repayments
    /// re-enter it — so this can never touch a borrower's position or the interest owed to the reserve;
    /// it only shrinks how much NEW lending the facility can write.
    function withdrawIdle(uint256 amount) external nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        essey.safeTransfer(treasury, amount);
        emit IdleWithdrawn(treasury, amount);
    }

    // ---------------------------------------------------------------- borrow / repay

    /// Open a fixed-term, FIXED-DRAW loan against a Don you own: exactly `ltvBps` of the live floor,
    /// in $ESSEY, for `termSeconds` in [MIN_TERM, MAX_TERM]. The term's interest — priced on the same
    /// floor read (the value basis) — is deducted from the disbursement and routed 70/30 in this same
    /// tx; the borrower owes back the full draw. `msg.value` must cover `originationFee()` — exactly
    /// the fee forwards to the feeSink, any excess refunds at the end. The Don is liened in place — it
    /// stays in your wallet, stays staked, keeps earning — but cannot move until the debt clears. One
    /// open loan per Don; no top-ups (repay and re-borrow to re-lever onto a risen floor).
    function borrow(uint256 donId, uint256 termSeconds) external payable nonReentrant whenNotFrozen {
        uint256 fee = originationFee();
        if (msg.value < fee) revert WrongFee();
        if (termSeconds < MIN_TERM || termSeconds > MAX_TERM) revert BadTerm();
        if (don.ownerOf(donId) != msg.sender) revert NotDonOwner();
        if (loans[donId].borrower != address(0)) revert LoanExists();

        // One floor read prices both legs: the draw (ltvBps of it) and the discount-note interest
        // (rateBps of it, scaled by the term), collected NOW out of the disbursement. The constructor
        // invariant keeps prepaid strictly below principal — guarded anyway so a degenerate state
        // fails closed rather than underflowing.
        uint256 floorNow = reserve.floorPerDon();
        uint256 principal = (floorNow * ltvBps) / BPS;
        if (principal == 0) revert ZeroAmount(); // an unfunded floor lends nothing
        uint256 prepaid = (floorNow * rateBps * termSeconds) / (BPS * YEAR);
        if (prepaid >= principal) revert PrepaidExceedsPrincipal();

        uint64 n = ++loanNonce;
        uint64 expiry = uint64(block.timestamp + termSeconds);
        loans[donId] = Loan({
            borrower: msg.sender,
            principal: principal,
            lateAccrued: 0,
            expiry: expiry,
            lateAccrual: expiry,
            nonce: n
        });
        totalPrincipal += principal;

        don.setLien(donId, true); // transfer-locked in the borrower's wallet
        if (fee > 0) {
            (bool ok,) = feeSink.call{value: fee}(""); // exactly the fee joins the mint-fee ETH->stock pipe
            if (!ok) revert FeeForwardFailed();
            emit OriginationPaid(donId, fee);
        }
        _routeInterest(prepaid); // banked up front — 70% stock pot, 30% floor, in the borrow tx
        essey.safeTransfer(msg.sender, principal - prepaid);
        emit Borrowed(donId, msg.sender, principal, uint64(termSeconds), prepaid, n);
        if (msg.value > fee) {
            // Overpayment (a fee quote can move between quote and inclusion) returns to the payer,
            // last — state fully settled, still under the reentrancy guard.
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// Pay a loan down (anyone may pay — paying someone's debt is a gift). Late interest settles first
    /// and is routed 70/30 (stock pot / floor); principal re-enters the lendable balance. The prepaid
    /// term interest is never part of debt — it was collected at borrow and never refunds.
    /// Full repayment releases the lien. Overpayment is not pulled: at most the outstanding debt moves.
    function repay(uint256 donId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Loan storage l = loans[donId];
        if (l.borrower == address(0)) revert NoLoan();
        if (amount == 0) revert ZeroAmount();
        _accrueLate(l);

        uint256 lateDue = l.lateAccrued;
        uint256 latePaid = amount < lateDue ? amount : lateDue;
        uint256 principalPaid = amount - latePaid;
        if (principalPaid > l.principal) principalPaid = l.principal;
        paid = latePaid + principalPaid;

        l.lateAccrued = lateDue - latePaid;
        l.principal -= principalPaid;
        totalPrincipal -= principalPaid;

        essey.safeTransferFrom(msg.sender, address(this), paid);
        _routeInterest(latePaid); // 70% stock for staked Dons / 30% floor for everyone

        bool closed = l.principal == 0 && l.lateAccrued == 0;
        if (closed) {
            delete loans[donId];
            don.setLien(donId, false); // the Don walks free
        }
        emit Repaid(donId, msg.sender, latePaid, principalPaid, closed);
    }

    // ---------------------------------------------------------------- liquidation

    /// Liquidate a defaulted loan — either trigger opens it: debt above `liqThresholdBps` of the LIVE
    /// floor (the ratio), or `expiry + defaultGraceSeconds` passed (the calendar). Permissionless and
    /// capital-free: the facility seizes the liened Don, redeems it at the DonReserve floor, and settles
    /// from the proceeds — tip to the caller, late interest split 70/30 (stock/floor), principal back to
    /// the lendable balance, surplus to the borrower. The Don is consumed by the redemption (locked in
    /// the reserve, Vault and membership forfeited). If proceeds somehow fall short (they cannot while
    /// the floor is monotone and the 20pp gap holds at the calendar trigger), the shortfall is written
    /// off against the facility — borrowers and the reserve are never owed by anyone else.
    function liquidate(uint256 donId) external nonReentrant {
        Loan storage l = loans[donId];
        address borrower = l.borrower;
        if (borrower == address(0)) revert NoLoan();
        _accrueLate(l);

        uint256 debt = l.principal + l.lateAccrued;
        uint256 threshold = liquidationThreshold();
        bool pastDefault = block.timestamp > uint256(l.expiry) + defaultGraceSeconds;
        if (debt <= threshold && !pastDefault) revert NotLiquidatable(debt, threshold);

        uint256 lateDue = l.lateAccrued;
        uint256 principalDue = l.principal;
        totalPrincipal -= principalDue;
        delete loans[donId]; // effects fully settled before any external call

        // Seize: the facility may move a LIENED Don (Don._isAuthorized) — pull it here, then redeem it
        // at the floor. Both transfers fire the Bell hook (tier clears — it's being liquidated).
        don.transferFrom(borrower, address(this), donId);
        don.setLien(donId, false); // custody is ours; the redeem transfer below must not be blocked
        don.approve(address(reserve), donId);
        uint256 proceeds = reserve.redeem(donId);

        // Waterfall: caller tip -> late interest (split stock/floor) -> principal (stays lendable) -> borrower.
        uint256 tip = (proceeds * liqTipBps) / BPS;
        uint256 available = proceeds - tip;
        uint256 lateRecovered = available < lateDue ? available : lateDue;
        available -= lateRecovered;
        uint256 principalRecovered = available < principalDue ? available : principalDue;
        available -= principalRecovered;

        if (tip > 0) essey.safeTransfer(msg.sender, tip);
        _routeInterest(lateRecovered); // same 70/30 split as a voluntary repay
        if (available > 0) essey.safeTransfer(borrower, available); // surplus is the borrower's

        emit Liquidated(donId, msg.sender, proceeds, lateRecovered + principalRecovered, available, tip);
    }
}
