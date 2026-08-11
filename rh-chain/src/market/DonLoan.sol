// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Don} from "./Don.sol";
import {DonReserve} from "./DonReserve.sol";

/// DonLoan — borrow $ESSEY against your Don, the proven NFT-loan desk mechanic rebuilt on Essey's
/// provable floor. 15% APR, 50% LTV — proven desk numbers.
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
/// LIQUIDATION NEEDS NO LIQUIDATOR CAPITAL: past the threshold, anyone triggers it; the facility seizes
/// the liened Don and redeems it at the DonReserve floor — the Don's own backing repays the debt. A
/// small tip pays the caller, the surplus returns to the borrower, and the Don is consumed (locked in
/// the reserve, membership forfeited). WARNING to borrowers (surface in UI): the Don's Vault — with any
/// unclaimed dividends — travels with the redeemed Don and is forfeited too; service your loan.
///
/// THE FLYWHEEL: every wei of interest (on repay and on liquidation recovery) is sent to the
/// DonReserve, raising the floor for every Don. Borrowing activity strengthens the collateral of all.
///
/// PROVABLE SOLVENCY (dregg): every loan stores its canonical solvency tuple — (facility, borrower,
/// debt, floor, ltvBps, nonce), amounts in WHOLE ESSEY so they fit the circuit's 64-bit bounds — which
/// the dregg prover commits with Poseidon and proves `debt * 10000 <= floor * ltvBps` under the
/// existing Groth16 verifier. The circuit's collateral-type binding generalizes; no circuit change.
///
/// TRUST SURFACE: adminless over user funds. `treasury` may withdraw only IDLE funding (protocol seed
/// sitting unlent) — outstanding debt is owed to the facility and returns on repay; no role can touch a
/// borrower's collateral except through the public liquidation path.
contract DonLoan is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable essey;
    Don public immutable don;
    DonReserve public immutable reserve; // floor source, redemption sink for seizures, interest sink
    address public immutable treasury; // may reclaim idle (unlent) funding only

    uint256 public immutable ltvBps; // 5000 = borrow up to 50% of the floor
    uint256 public immutable liqThresholdBps; // 7000 = liquidatable once debt > 70% of the LIVE floor
    uint256 public immutable rateBps; // 1500 = 15% APR, simple (non-compounding) interest
    uint256 public immutable liqTipBps; // caller's cut of liquidation proceeds (e.g. 100 = 1%)

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    /// Same risk discipline as EsseyMarkets: the liquidation threshold must sit a full 20pp above LTV,
    /// so a loan has years of accrual (and a rising floor) between origination and the trigger.
    uint256 internal constant MIN_RISK_GAP_BPS = 2_000;
    uint256 internal constant MAX_LIQ_THRESHOLD_BPS = 9_000;
    uint256 internal constant MAX_TIP_BPS = 500;

    struct Loan {
        address borrower;
        uint256 principal; // outstanding principal, 18-dec ESSEY
        uint256 accrued; // interest checkpointed but unpaid
        uint64 lastAccrual;
        uint64 nonce; // this loan's slot in the dregg proof stream
    }

    mapping(uint256 => Loan) public loans; // donId => loan (one open loan per Don)
    uint256 public totalPrincipal; // sum of outstanding principals
    uint64 public loanNonce; // monotone loan counter (proof-tuple nonce)

    event Funded(address indexed from, uint256 amount);
    event Borrowed(uint256 indexed donId, address indexed borrower, uint256 amount, uint64 nonce);
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

    error BadConfig();
    error ZeroAmount();
    error NotDonOwner();
    error LoanExists();
    error NoLoan();
    error ExceedsLtv(uint256 requested, uint256 maxBorrowable);
    error NotLiquidatable(uint256 debt, uint256 threshold);
    error NotTreasury();

    constructor(
        IERC20 essey_,
        Don don_,
        DonReserve reserve_,
        address treasury_,
        uint256 ltvBps_,
        uint256 liqThresholdBps_,
        uint256 rateBps_,
        uint256 liqTipBps_
    ) {
        if (
            address(essey_) == address(0) || address(don_) == address(0) || address(reserve_) == address(0)
                || treasury_ == address(0) || ltvBps_ == 0 || ltvBps_ + MIN_RISK_GAP_BPS > liqThresholdBps_
                || liqThresholdBps_ > MAX_LIQ_THRESHOLD_BPS || rateBps_ == 0 || rateBps_ > BPS
                || liqTipBps_ > MAX_TIP_BPS
        ) revert BadConfig();
        // The reserve must actually be the floor of THIS Don — a mismatched pairing would let borrowing
        // against one collection be priced by another's reserve.
        if (address(reserve_.don()) != address(don_)) revert BadConfig();
        essey = essey_;
        don = don_;
        reserve = reserve_;
        treasury = treasury_;
        ltvBps = ltvBps_;
        liqThresholdBps = liqThresholdBps_;
        rateBps = rateBps_;
        liqTipBps = liqTipBps_;
    }

    // ---------------------------------------------------------------- views

    /// $ESSEY currently available to lend.
    function lendable() public view returns (uint256) {
        return essey.balanceOf(address(this));
    }

    /// The most a Don can borrow right now: half (ltvBps) of the live floor.
    function maxBorrow() public view returns (uint256) {
        return (reserve.floorPerDon() * ltvBps) / BPS;
    }

    /// A loan's debt right now: principal + checkpointed interest + interest since the checkpoint.
    /// Simple (non-compounding) interest on principal, per second.
    function debtOf(uint256 donId) public view returns (uint256) {
        Loan storage l = loans[donId];
        if (l.borrower == address(0)) return 0;
        return l.principal + l.accrued + _pendingInterest(l);
    }

    /// Debt above this is liquidatable. Reads the LIVE floor, so funding the reserve heals loans.
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
            // tuple can only ever overstate risk to the prover, never understate it.
            uint64((debtOf(donId) + 1e18 - 1) / 1e18),
            uint64(reserve.floorPerDon() / 1e18),
            uint16(ltvBps),
            l.nonce
        );
    }

    function _pendingInterest(Loan storage l) internal view returns (uint256) {
        return (l.principal * rateBps * (block.timestamp - l.lastAccrual)) / (BPS * YEAR);
    }

    function _accrue(Loan storage l) internal {
        l.accrued += _pendingInterest(l);
        l.lastAccrual = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- funding

    /// Add lending capital. Permissionless — the treasury seeds it; anyone may deepen it. (A plain
    /// transfer works identically: `lendable` reads the balance.)
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        essey.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
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

    /// Open a loan against a Don you own: up to `ltvBps` of the live floor, in $ESSEY. The Don is liened
    /// in place — it stays in your wallet, stays staked, keeps earning — but cannot move until the debt
    /// clears. One open loan per Don; no top-ups (repay and re-borrow to re-lever).
    function borrow(uint256 donId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (don.ownerOf(donId) != msg.sender) revert NotDonOwner();
        if (loans[donId].borrower != address(0)) revert LoanExists();

        uint256 cap = maxBorrow();
        if (amount > cap) revert ExceedsLtv(amount, cap);

        uint64 n = ++loanNonce;
        loans[donId] = Loan({
            borrower: msg.sender,
            principal: amount,
            accrued: 0,
            lastAccrual: uint64(block.timestamp),
            nonce: n
        });
        totalPrincipal += amount;

        don.setLien(donId, true); // transfer-locked in the borrower's wallet
        essey.safeTransfer(msg.sender, amount);
        emit Borrowed(donId, msg.sender, amount, n);
    }

    /// Pay a loan down (anyone may pay — paying someone's debt is a gift). Interest settles first and is
    /// forwarded to the DonReserve, raising every Don's floor; principal re-enters the lendable balance.
    /// Full repayment releases the lien. Overpayment is not pulled: at most the outstanding debt moves.
    function repay(uint256 donId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Loan storage l = loans[donId];
        if (l.borrower == address(0)) revert NoLoan();
        if (amount == 0) revert ZeroAmount();
        _accrue(l);

        uint256 interestDue = l.accrued;
        uint256 interestPaid = amount < interestDue ? amount : interestDue;
        uint256 principalPaid = amount - interestPaid;
        if (principalPaid > l.principal) principalPaid = l.principal;
        paid = interestPaid + principalPaid;

        l.accrued = interestDue - interestPaid;
        l.principal -= principalPaid;
        totalPrincipal -= principalPaid;

        essey.safeTransferFrom(msg.sender, address(this), paid);
        if (interestPaid > 0) essey.safeTransfer(address(reserve), interestPaid); // floor rises for everyone

        bool closed = l.principal == 0 && l.accrued == 0;
        if (closed) {
            delete loans[donId];
            don.setLien(donId, false); // the Don walks free
        }
        emit Repaid(donId, msg.sender, interestPaid, principalPaid, closed);
    }

    // ---------------------------------------------------------------- liquidation

    /// Liquidate an underwater loan (debt above `liqThresholdBps` of the LIVE floor). Permissionless and
    /// capital-free: the facility seizes the liened Don, redeems it at the DonReserve floor, and settles
    /// from the proceeds — tip to the caller, interest to the reserve, principal back to the lendable
    /// balance, surplus to the borrower. The Don is consumed by the redemption (locked in the reserve,
    /// Vault and membership forfeited). If proceeds somehow fall short (they cannot while the floor is
    /// monotone and the 20pp gap holds), the shortfall is written off against the facility — borrowers
    /// and the reserve are never owed by anyone else.
    function liquidate(uint256 donId) external nonReentrant {
        Loan storage l = loans[donId];
        address borrower = l.borrower;
        if (borrower == address(0)) revert NoLoan();
        _accrue(l);

        uint256 debt = l.principal + l.accrued;
        uint256 threshold = liquidationThreshold();
        if (debt <= threshold) revert NotLiquidatable(debt, threshold);

        uint256 interestDue = l.accrued;
        uint256 principalDue = l.principal;
        totalPrincipal -= principalDue;
        delete loans[donId]; // effects fully settled before any external call

        // Seize: the facility may move a LIENED Don (Don._isAuthorized) — pull it here, then redeem it
        // at the floor. Both transfers fire the Bell hook (tier clears — it's being liquidated).
        don.transferFrom(borrower, address(this), donId);
        don.setLien(donId, false); // custody is ours; the redeem transfer below must not be blocked
        don.approve(address(reserve), donId);
        uint256 proceeds = reserve.redeem(donId);

        // Waterfall: caller tip -> interest (to the reserve) -> principal (stays lendable) -> borrower.
        uint256 tip = (proceeds * liqTipBps) / BPS;
        uint256 available = proceeds - tip;
        uint256 interestRecovered = available < interestDue ? available : interestDue;
        available -= interestRecovered;
        uint256 principalRecovered = available < principalDue ? available : principalDue;
        available -= principalRecovered;

        if (tip > 0) essey.safeTransfer(msg.sender, tip);
        if (interestRecovered > 0) essey.safeTransfer(address(reserve), interestRecovered);
        if (available > 0) essey.safeTransfer(borrower, available); // surplus is the borrower's

        emit Liquidated(donId, msg.sender, proceeds, interestRecovered + principalRecovered, available, tip);
    }
}
