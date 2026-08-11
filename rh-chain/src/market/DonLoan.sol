// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Don} from "./Don.sol";
import {DonReserve} from "./DonReserve.sol";
import {Guarded} from "./Guarded.sol";

/// DonLoan — the reference NFT-desk loan, rebuilt faithfully on Essey's provable floor: interest is
/// PREPAID IN ETH at signing, the principal is disbursed in full ($ESSEY) and repaid 1:1, and default
/// is a CALENDAR event — no accrual, no penalty phase, no late interest.
///
/// THE TERM LOAN, FIXED-DRAW: `borrow(donId, term)` draws exactly `ltvBps` of the live floor — every
/// loan is a full draw against the value line, which tracks the rising floor. The whole draw is
/// disbursed in $ESSEY; the borrower owes back exactly that principal, flat, any time up to expiry.
/// There is NO $ESSEY interest and NO netting: the desk's fee is a SEPARATE ETH leg, prepaid for the
/// full term in the borrow tx.
///
/// INTEREST IS ETH, PREPAID, FLOOR-SCALED: `prepaidEth = ethPerFloorPerYearWad * floorPerDon() * term /
/// (YEAR * 1e18)`, clamped to MAX_PREPAID_ETH. This reproduces the reference desk's VALUE-SCALED upfront
/// ETH fee — theirs scales with their NFT-AMM price, ours scales with the Don's own floor — using our
/// OWN `floorPerDon()` as the value source and a fixed ETH coefficient, so it is ORACLE-FREE: no
/// per-NFT price read, no feed. `ethPerFloorPerYearWad` is wei of ETH charged per 1e18 of floor-ESSEY
/// per full-year term (default 0 = free); the treasury retunes it ONLY for ESSEY->ETH price drift,
/// exactly like the mint fee — it does NOT track floor growth, because the fee already scales with the
/// floor. The output clamp guarantees no coefficient and no floor growth can ever price a borrow beyond
/// MAX_PREPAID_ETH. The floor snapshot read to size the principal is REUSED to size the fee — one read.
/// The prepaid ETH is forwarded IN the borrow tx, split 70/30 — the same StockBooster/protocol shape
/// the reference desk uses: `ethFeeStockShareBps` (70%) to `feeSink` (the ETH->stock pipe that buys
/// Robinhood stock for staked Dons), the remainder to `treasury`. Any `msg.value` above the prepaid
/// amount is refunded to the borrower LAST, under the reentrancy guard.
///
/// WHY ESSEY-DENOMINATED PRINCIPAL: the reference desk lends the asset its floor is priced in, with no
/// external oracle — the protocol's own floor IS the price. Essey's Don floor is
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
/// TWO LIQUIDATION TRIGGERS, both permissionless and capital-free: (a) the CALENDAR — `expiry +
/// defaultGraceSeconds` has passed, whatever the ratio (the LIVE trigger; interest was prepaid, so a
/// borrower who never repays simply loses the collateral once the grace clock runs out) — and (b) the
/// RATIO — debt above `liqThresholdBps` of the LIVE floor. Under this model the ratio trigger is
/// STRUCTURALLY UNREACHABLE: debt is flat at principal (<= 50% of a non-decreasing floor) and can never
/// climb to the 70% threshold. It is kept CODE-LIVE ON PURPOSE — a dead-but-present safety net, so a
/// future param change can't silently delete it. Settlement is one waterfall either way: the facility
/// seizes the liened Don, redeems it at the DonReserve floor, tips the caller, restores principal to
/// the pot, and returns the SURPLUS TO THE BORROWER — a defaulter loses the Don, not the equity above
/// the debt. WARNING to borrowers (surface in UI): the Don's Vault — with any unclaimed dividends —
/// travels with the redeemed Don and is forfeited too; service your loan.
///
/// THE FLYWHEEL: all interest is ETH, prepaid at borrow, split 70% to `feeSink` (the fee->stock router
/// that buys Robinhood stock for staked Dons) and 30% to `treasury`. Borrowing activity visibly pays
/// the room — the same 70/30 shape the AMM's fees already follow.
///
/// PROVABLE SOLVENCY (dregg): every loan stores its canonical solvency tuple — (facility, borrower,
/// debt, floor, ltvBps, nonce), amounts in WHOLE ESSEY so they fit the circuit's 64-bit bounds — which
/// the dregg prover commits with Poseidon and proves `debt * 10000 <= floor * ltvBps` under the
/// existing Groth16 verifier. Debt is exactly the principal, ceiled, so the whole-token tuple can only
/// overstate risk. The circuit's collateral-type binding generalizes; no circuit change.
///
/// TRUST SURFACE: adminless over user funds. `treasury` may withdraw only IDLE funding (protocol seed
/// sitting unlent) — outstanding debt is owed to the facility and returns on repay; no role can touch a
/// borrower's collateral except through the public liquidation path.
contract DonLoan is ReentrancyGuard, Guarded {
    using SafeERC20 for IERC20;

    IERC20 public immutable essey;
    Don public immutable don;
    DonReserve public immutable reserve; // floor source, redemption sink for seizures
    address public immutable feeSink; // ethFeeStockShareBps of prepaid ETH -> the fee->stock router
    address public immutable treasury; // gets the remainder of the prepaid ETH; may reclaim idle funding

    uint256 public immutable ltvBps; // 5000 = borrow up to 50% of the floor
    uint256 public immutable liqThresholdBps; // 7000 = liquidatable once debt > 70% of the LIVE floor
    uint256 public immutable defaultGraceSeconds; // past expiry + this, calendar liquidation opens
    uint256 public immutable liqTipBps; // caller's cut of liquidation proceeds (e.g. 100 = 1%)
    uint256 public immutable ethFeeStockShareBps; // 7000 = 70% of prepaid ETH -> feeSink; remainder -> treasury

    /// The ETH-per-floor coefficient: wei of ETH charged per 1e18 of floor-ESSEY, per full-year term.
    /// The per-borrow prepaid scales with `floorPerDon()` off this; treasury-tunable ONLY for ESSEY->ETH
    /// price drift (like the mint fee). 0 = free borrowing.
    uint256 public ethPerFloorPerYearWad;
    /// Overflow guard on the coefficient — deliberately generous (the real limiter is the output clamp
    /// below); keeps `wad * floor * term` far inside uint256 for any conceivable floor.
    uint256 public constant MAX_ETH_PER_FLOOR_YEAR_WAD = 1 ether;
    /// Hard clamp on the COMPUTED prepaid, applied after the floor-scaled multiply: no coefficient and
    /// no floor growth can ever price a borrow beyond this in prepaid ETH.
    uint256 public constant MAX_PREPAID_ETH = 1 ether;

    /// Term bounds: long enough that prepaid interest is real revenue, short enough that the calendar
    /// trigger (expiry + grace) keeps every loan on a bounded clock.
    uint256 public constant MIN_TERM = 7 days;
    uint256 public constant MAX_TERM = 365 days;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    /// Same risk discipline as EsseyMarkets: the liquidation threshold must sit a full 20pp above LTV.
    /// Debt is FLAT at principal (<= ltvBps of the origination floor) and the floor is non-decreasing,
    /// so the ratio trigger can never actually fire — the calendar is the live one. The gap is enforced
    /// anyway so the dead ratio backstop stays honest if a future param change ever revives it.
    uint256 internal constant MIN_RISK_GAP_BPS = 2_000;
    uint256 internal constant MAX_LIQ_THRESHOLD_BPS = 9_000;
    uint256 internal constant MAX_TIP_BPS = 500;
    /// Grace bounds: at least a week to cure a missed expiry, at most a quarter before the pot's
    /// capital can be recycled.
    uint256 internal constant MIN_GRACE = 7 days;
    uint256 internal constant MAX_GRACE = 90 days;

    struct Loan {
        address borrower;
        uint256 principal; // owed back in full, 1:1, flat — interest was prepaid in ETH at signing
        uint64 expiry; // end of the term; past expiry + grace the calendar trigger opens
        uint64 nonce; // this loan's slot in the dregg proof stream
    }

    mapping(uint256 => Loan) public loans; // donId => loan (one open loan per Don)
    uint256 public totalPrincipal; // sum of outstanding principals
    uint64 public loanNonce; // monotone loan counter (proof-tuple nonce)

    event Funded(address indexed from, uint256 amount);
    event Borrowed(
        uint256 indexed donId, address indexed borrower, uint256 amount, uint64 termSeconds, uint256 prepaidEth, uint64 nonce
    );
    event InterestPrepaid(uint256 indexed donId, uint256 ethAmount);
    event Repaid(uint256 indexed donId, address indexed payer, uint256 principalPaid, bool closed);
    event Liquidated(
        uint256 indexed donId,
        address indexed caller,
        uint256 proceeds,
        uint256 debtRecovered,
        uint256 surplusToBorrower,
        uint256 tip
    );
    event IdleWithdrawn(address indexed to, uint256 amount);
    event EthRatePerFloorYearSet(uint256 wad);

    error BadConfig();
    error ZeroAmount();
    error BadTerm();
    error NotDonOwner();
    error LoanExists();
    error NoLoan();
    error NotLiquidatable(uint256 debt, uint256 threshold);
    error NotTreasury();
    error WrongFee();
    error FeeTooHigh();
    error FeeForwardFailed();
    error RefundFailed();

    /// One constructor argument — the config as a struct (the DonFeeRouter shape; loose params overflow
    /// the legacy pipeline's stack).
    struct Config {
        IERC20 essey;
        Don don;
        DonReserve reserve;
        address feeSink;
        address treasury;
        uint256 ltvBps;
        uint256 liqThresholdBps;
        uint256 defaultGraceSeconds;
        uint256 liqTipBps;
        uint256 ethPerFloorPerYearWad; // initial ETH-per-floor coefficient, treasury-settable later; 0 = free
        uint256 ethFeeStockShareBps; // 7000 = 70% of prepaid ETH -> feeSink, remainder -> treasury
        address guardian;
    }

    constructor(Config memory c) Guarded(c.guardian) {
        if (
            address(c.essey) == address(0) || address(c.don) == address(0) || address(c.reserve) == address(0)
                || c.feeSink == address(0) || c.treasury == address(0) || c.ltvBps == 0
                || c.ltvBps + MIN_RISK_GAP_BPS > c.liqThresholdBps || c.liqThresholdBps > MAX_LIQ_THRESHOLD_BPS
                || c.defaultGraceSeconds < MIN_GRACE || c.defaultGraceSeconds > MAX_GRACE
                || c.liqTipBps > MAX_TIP_BPS || c.ethFeeStockShareBps > BPS
                || c.ethPerFloorPerYearWad > MAX_ETH_PER_FLOOR_YEAR_WAD
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
        defaultGraceSeconds = c.defaultGraceSeconds;
        liqTipBps = c.liqTipBps;
        ethFeeStockShareBps = c.ethFeeStockShareBps;
        ethPerFloorPerYearWad = c.ethPerFloorPerYearWad;
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

    /// The ETH interest owed up front for a term of `termSeconds`, floor-scaled off the LIVE floor and
    /// clamped to MAX_PREPAID_ETH. The whole amount is forwarded (70/30) in the borrow tx; nothing
    /// accrues after.
    function prepaidEth(uint256 termSeconds) public view returns (uint256) {
        return _prepaidFromFloor(reserve.floorPerDon(), termSeconds);
    }

    /// The floor-scaled prepaid, off a given floor snapshot: `wad * floor * term / (YEAR * 1e18)`, then
    /// clamped. The clamp is the price-brick guard — it caps the toll no matter how high the floor or
    /// coefficient climb.
    function _prepaidFromFloor(uint256 floor_, uint256 termSeconds) internal view returns (uint256 wei_) {
        wei_ = (ethPerFloorPerYearWad * floor_ * termSeconds) / (YEAR * 1e18);
        if (wei_ > MAX_PREPAID_ETH) wei_ = MAX_PREPAID_ETH;
    }

    /// A loan's debt right now: exactly the principal, FLAT FOREVER. The term's interest was prepaid in
    /// ETH at signing, so nothing accrues — past expiry the debt is still just the principal, and the
    /// borrower's only exposure is the calendar liquidation clock.
    function debtOf(uint256 donId) public view returns (uint256) {
        Loan storage l = loans[donId];
        if (l.borrower == address(0)) return 0;
        return l.principal;
    }

    /// Debt above this is liquidatable by RATIO. Reads the LIVE floor, so funding the reserve heals
    /// loans. Under this model the ratio can never be crossed (flat principal <= 50% of a non-decreasing
    /// floor); the calendar trigger — expiry + grace — is the live one and never heals.
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
            // tuple can only ever overstate risk to the prover, never understate it. Debt is exactly the
            // principal under this model, so the tuple stays conservative.
            uint64((debtOf(donId) + 1e18 - 1) / 1e18),
            uint64(reserve.floorPerDon() / 1e18),
            uint16(ltvBps),
            l.nonce
        );
    }

    // ---------------------------------------------------------------- funding

    /// Add lending capital. Permissionless — the treasury seeds it; anyone may deepen it. (A plain
    /// transfer works identically: `lendable` reads the balance.)
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        essey.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// Tune the ETH-per-floor coefficient (treasury = the multisig). The per-borrow prepaid scales with
    /// `floorPerDon()` off this and is clamped to MAX_PREPAID_ETH regardless, so this is capped only by a
    /// generous overflow guard. Retune it for ESSEY->ETH drift, not for floor growth. 0 = free.
    function setEthRatePerFloorYear(uint256 wad) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (wad > MAX_ETH_PER_FLOOR_YEAR_WAD) revert FeeTooHigh();
        ethPerFloorPerYearWad = wad;
        emit EthRatePerFloorYearSet(wad);
    }

    /// Reclaim IDLE capital only. Outstanding principal has already left the balance, and repayments
    /// re-enter it — so this can never touch a borrower's position; it only shrinks how much NEW lending
    /// the facility can write.
    function withdrawIdle(uint256 amount) external nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        essey.safeTransfer(treasury, amount);
        emit IdleWithdrawn(treasury, amount);
    }

    // ---------------------------------------------------------------- borrow / repay

    /// Open a fixed-term, FIXED-DRAW loan against a Don you own: exactly `ltvBps` of the live floor,
    /// disbursed IN FULL in $ESSEY, for `termSeconds` in [MIN_TERM, MAX_TERM]. The term's interest is a
    /// SEPARATE ETH leg, prepaid here: `msg.value` must cover `prepaidEth(termSeconds)` — exactly that
    /// forwards 70/30 (feeSink / treasury) in this tx, any excess refunds at the end. If the prepaid is
    /// zero (rate 0, or a term that floors to 0), `msg.value` must be exactly 0 — no accidental tips.
    /// The borrower owes back the full principal, flat, 1:1. The Don is liened in place — it stays in
    /// your wallet, stays staked, keeps earning — but cannot move until the debt clears. One open loan
    /// per Don; no top-ups (repay and re-borrow to re-lever onto a risen floor).
    function borrow(uint256 donId, uint256 termSeconds) external payable nonReentrant whenNotFrozen {
        if (termSeconds < MIN_TERM || termSeconds > MAX_TERM) revert BadTerm();

        // ONE floor read prices both legs: the draw (ltvBps of it) and the floor-scaled prepaid ETH
        // (clamped). The whole draw is disbursed — no netting; interest is the ETH leg. An unfunded
        // floor lends nothing, so borrowing fails closed.
        uint256 floorNow = reserve.floorPerDon();
        uint256 principal = (floorNow * ltvBps) / BPS;
        uint256 prepaid = _prepaidFromFloor(floorNow, termSeconds);

        // Exact-zero discipline when there's nothing to charge; otherwise the value must cover it.
        if (prepaid == 0) {
            if (msg.value != 0) revert WrongFee();
        } else if (msg.value < prepaid) {
            revert WrongFee();
        }
        if (don.ownerOf(donId) != msg.sender) revert NotDonOwner();
        if (loans[donId].borrower != address(0)) revert LoanExists();
        if (principal == 0) revert ZeroAmount();

        uint64 n = ++loanNonce;
        loans[donId] = Loan({
            borrower: msg.sender,
            principal: principal,
            expiry: uint64(block.timestamp + termSeconds),
            nonce: n
        });
        totalPrincipal += principal;

        don.setLien(donId, true); // transfer-locked in the borrower's wallet
        if (prepaid > 0) {
            // Prepaid ETH interest, forwarded now: 70% to the ETH->stock pipe, 30% to the treasury.
            uint256 toStock = (prepaid * ethFeeStockShareBps) / BPS;
            uint256 toTreasury = prepaid - toStock;
            if (toStock > 0) {
                (bool okS,) = feeSink.call{value: toStock}("");
                if (!okS) revert FeeForwardFailed();
            }
            if (toTreasury > 0) {
                (bool okT,) = treasury.call{value: toTreasury}("");
                if (!okT) revert FeeForwardFailed();
            }
            emit InterestPrepaid(donId, prepaid);
        }
        essey.safeTransfer(msg.sender, principal); // the full draw
        emit Borrowed(donId, msg.sender, principal, uint64(termSeconds), prepaid, n);
        if (msg.value > prepaid) {
            // Overpayment (a rate quote can move between quote and inclusion) returns to the payer,
            // last — state fully settled, still under the reentrancy guard.
            (bool ok,) = msg.sender.call{value: msg.value - prepaid}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// Pay a loan down in $ESSEY, 1:1 (anyone may pay — paying someone's debt is a gift). The prepaid
    /// ETH interest is never part of debt — it was collected at borrow and never refunds. Full repayment
    /// releases the lien and deletes the loan. Overpayment is not pulled: at most the outstanding
    /// principal moves.
    function repay(uint256 donId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Loan storage l = loans[donId];
        if (l.borrower == address(0)) revert NoLoan();
        if (amount == 0) revert ZeroAmount();

        paid = amount < l.principal ? amount : l.principal;
        l.principal -= paid;
        totalPrincipal -= paid;

        essey.safeTransferFrom(msg.sender, address(this), paid); // re-enters the lendable balance

        bool closed = l.principal == 0;
        if (closed) {
            delete loans[donId];
            don.setLien(donId, false); // the Don walks free
        }
        emit Repaid(donId, msg.sender, paid, closed);
    }

    // ---------------------------------------------------------------- liquidation

    /// Liquidate a defaulted loan. The LIVE trigger is the CALENDAR: `expiry + defaultGraceSeconds` has
    /// passed. The RATIO trigger — debt above `liqThresholdBps` of the LIVE floor — is kept CODE-LIVE
    /// but is structurally unreachable (flat principal <= 50% of a non-decreasing floor never crosses
    /// 70%); it stands as a dead-but-present safety net. Permissionless and capital-free: the facility
    /// seizes the liened Don, redeems it at the DonReserve floor, and settles from the proceeds — tip to
    /// the caller, principal back to the lendable balance, surplus to the borrower. The Don is consumed
    /// by the redemption (locked in the reserve, Vault and membership forfeited). If proceeds somehow
    /// fall short (they cannot while the floor is monotone and the 20pp gap holds at the calendar
    /// trigger), the shortfall is written off against the facility — borrowers are never owed by anyone.
    function liquidate(uint256 donId) external nonReentrant {
        Loan storage l = loans[donId];
        address borrower = l.borrower;
        if (borrower == address(0)) revert NoLoan();

        uint256 debt = l.principal; // flat — interest was prepaid in ETH
        uint256 threshold = liquidationThreshold();
        // The ratio comparison stays LIVE (never removed) even though it can't fire under this model;
        // the calendar is the trigger that actually opens liquidation.
        bool pastDefault = block.timestamp > uint256(l.expiry) + defaultGraceSeconds;
        if (debt <= threshold && !pastDefault) revert NotLiquidatable(debt, threshold);

        uint256 principalDue = l.principal;
        totalPrincipal -= principalDue;
        delete loans[donId]; // effects fully settled before any external call

        // Seize: the facility may move a LIENED Don (Don._isAuthorized) — pull it here, then redeem it
        // at the floor. Both transfers fire the Bell hook (tier clears — it's being liquidated).
        don.transferFrom(borrower, address(this), donId);
        don.setLien(donId, false); // custody is ours; the redeem transfer below must not be blocked
        don.approve(address(reserve), donId);
        uint256 proceeds = reserve.redeem(donId);

        // Waterfall: caller tip -> principal (stays lendable) -> borrower. No interest leg (ETH-prepaid).
        uint256 tip = (proceeds * liqTipBps) / BPS;
        uint256 available = proceeds - tip;
        uint256 principalRecovered = available < principalDue ? available : principalDue;
        available -= principalRecovered; // principalRecovered stays in this contract = lendable again

        if (tip > 0) essey.safeTransfer(msg.sender, tip);
        if (available > 0) essey.safeTransfer(borrower, available); // surplus is the borrower's

        emit Liquidated(donId, msg.sender, proceeds, principalRecovered, available, tip);
    }
}
