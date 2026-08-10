// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// TravelVoucher — a USDG-backed travel-package voucher (TravelSwap x Essey, V1).
///
/// Each voucher is a claim on a PREDEFINED travel package whose value in USDG is LOCKED at issue time (the
/// "capture the value so it can't drift" requirement, on-chain). Every outstanding voucher is backed 1:1 by
/// USDG held in this contract, so the system is PROVABLY SOLVENT BY CONSTRUCTION: a voucher can only be
/// minted by depositing its full backing, and the invariant `reserve() >= reserved` holds after every call.
/// This is stronger than the stock-case bankroll — the backing IS the stable, so there is no oracle, no
/// session gate, and no par-drift to manage.
///
/// V1 deliberately does NOT touch Expedia/Duffel or pre-book anything. The actual trip is arranged MANUALLY
/// by TravelSwap at redemption (booked FRESH for the winner), so the immutable-email constraint on an
/// existing reservation never applies in V1 — that is a Phase-B concern.
///
/// A holder (typically a Gotcha/Case winner) has three exits, and USDG only ever leaves this contract via the
/// last two — each of which BURNS the voucher it settles:
///   - HOLD.
///   - SELL BACK  -> `lockedValue - spread` USDG to the holder; the spread is house revenue (the fee sink).
///   - REDEEM     -> the full backing goes to TravelSwap, which books the trip off-chain (the `Redeemed`
///                   event is the manual-fulfilment signal). The holder's claim is now off-chain.
///
/// Privileged roles are minimal and CANNOT touch the backing: `issuer` mints (and can only ever ADD backing),
/// and `admin` sets the predefined tier values + the sell-back spread, rotates the settlement address (behind
/// a 2-day timelock — a change is public 2 days ahead, so a hostile redirect is never SUDDEN, though an
/// honest-admin trust assumption remains; see `travelSwap`), and may skim only the SURPLUS above the
/// outstanding backing (donations). Neither role can move a holder's backed USDG; the reserve's backing is
/// only ever reduced by a holder redeeming/selling their OWN voucher.
///
/// KNOWN V1 TRADEOFF — no expiry: a voucher whose holder never sells or redeems keeps its backing reserved
/// forever (there is no admin reclaim of live backing, by design — that is the solvency guarantee). Abandoned
/// backing is therefore locked, not lost; a holder can always still exit. Reclaim-on-expiry is a Phase-B item.
contract TravelVoucher is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint16 internal constant MAX_SPREAD_BPS = 2_000; // the house can never confiscate more than 20% on sell-back
    uint256 public constant SETTLE_TIMELOCK = 2 days; // delay on rotating the settlement address (see below)

    /// The backing/settlement token. MUST be a standard ERC20 — NOT fee-on-transfer or rebasing — or the
    /// `reserve() >= reserved` solvency invariant would not hold (less than `value*count` would arrive on
    /// issue). Real USDG (Global Dollar) is a standard 6-dec token; the address is immutable.
    IERC20 public immutable usdg;
    address public immutable issuer; // mints vouchers by depositing their full backing

    /// Where a redemption's backing is sent for TravelSwap to fund the (manual, off-chain) booking. USDG is a
    /// freezable regulated stable, so this is ROTATABLE — but only behind a 2-day timelock. That timelock does
    /// NOT make a hostile redirect impossible (a malicious admin could still repoint this and capture the
    /// backing of anyone who redeems afterwards); it makes any change PUBLIC 2 days ahead, so an alert holder
    /// can `sellBack` and exit first — forfeiting only the spread. The trust assumption is an honest admin
    /// multisig; the timelock bounds the damage of a compromised one to inattentive redeemers.
    address public travelSwap;
    address public pendingTravelSwap;
    uint256 public travelSwapEffectiveAt;

    address public admin; // sets tier values + spread (the operator multisig on mainnet)
    address public spreadRecipient; // sell-back spread destination (the Bell / fee sink)
    uint16 public sellBackSpreadBps; // the spread applied to NEW issues; each voucher locks its own at issue

    mapping(uint8 => uint256) public tierValue; // predefined package value in USDG (0 = unset/disabled)
    mapping(uint256 => uint256) public lockedValue; // tokenId => USDG value locked at issue
    mapping(uint256 => uint16) public lockedSpreadBps; // tokenId => sell-back spread locked at issue (front-run proof)
    mapping(uint256 => uint8) public voucherTier; // tokenId => tier (metadata for the fulfilment signal)
    uint256 public reserved; // sum of outstanding vouchers' locked values — the solvency figure
    uint256 public nextId = 1;

    event TierSet(uint8 indexed tier, uint256 value);
    event SpreadSet(uint16 bps, address recipient);
    event AdminChanged(address indexed admin);
    event TravelSwapProposed(address indexed to, uint256 effectiveAt);
    event TravelSwapChanged(address indexed to);
    event TravelSwapProposalCanceled(address indexed was);
    event SurplusSkimmed(address indexed to, uint256 amount);
    event Issued(address indexed to, uint8 indexed tier, uint256 fromId, uint256 count, uint256 value);
    event SoldBack(uint256 indexed id, address indexed holder, uint256 paid, uint256 spread);
    event Redeemed(uint256 indexed id, address indexed holder, uint8 tier, uint256 value); // TravelSwap fulfils

    error NotIssuer();
    error NotAdmin();
    error NotHolder();
    error BadTier();
    error BadSpread();
    error ZeroAddress();
    error TimelockNotElapsed();
    error NothingToSkim();

    constructor(
        string memory name_, // per-operator brand, e.g. "CoinVoyage Travel Voucher" (set once by the factory)
        string memory symbol_,
        IERC20 usdg_,
        address travelSwap_,
        address issuer_,
        address admin_,
        uint16 spreadBps_,
        address spreadRecipient_
    ) ERC721(name_, symbol_) {
        if (
            address(usdg_) == address(0) || travelSwap_ == address(0) || issuer_ == address(0)
                || admin_ == address(0) || spreadRecipient_ == address(0)
        ) revert ZeroAddress();
        if (spreadBps_ > MAX_SPREAD_BPS) revert BadSpread();
        usdg = usdg_;
        travelSwap = travelSwap_;
        issuer = issuer_;
        admin = admin_;
        sellBackSpreadBps = spreadBps_;
        spreadRecipient = spreadRecipient_;
    }

    // ---------------------------------------------------------------- admin config (never touches the reserve)

    /// Set a predefined tier's value. Only affects vouchers issued AFTER the change — already-minted vouchers
    /// keep the value locked at their own issue time, so this can never re-price an outstanding voucher.
    function setTier(uint8 tier, uint256 value) external {
        if (msg.sender != admin) revert NotAdmin();
        tierValue[tier] = value;
        emit TierSet(tier, value);
    }

    function setSpread(uint16 bps, address recipient) external {
        if (msg.sender != admin) revert NotAdmin();
        if (bps > MAX_SPREAD_BPS) revert BadSpread();
        if (recipient == address(0)) revert ZeroAddress();
        sellBackSpreadBps = bps;
        spreadRecipient = recipient;
        emit SpreadSet(bps, recipient);
    }

    function setAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        emit AdminChanged(admin_);
    }

    /// Propose a new settlement address (e.g. after the current one is frozen or must migrate). Takes effect
    /// only after SETTLE_TIMELOCK, so the change is public for 2 days and holders can `sellBack` meanwhile —
    /// a surprise redirect of redemptions is therefore impossible even with the admin key.
    function proposeTravelSwap(address to) external {
        if (msg.sender != admin) revert NotAdmin();
        if (to == address(0)) revert ZeroAddress();
        pendingTravelSwap = to;
        travelSwapEffectiveAt = block.timestamp + SETTLE_TIMELOCK;
        emit TravelSwapProposed(to, travelSwapEffectiveAt);
    }

    /// Commit a proposed settlement address once its timelock has elapsed. Permissionless — there is no
    /// discretion, only a chore anyone may finish.
    function commitTravelSwap() external {
        if (travelSwapEffectiveAt == 0 || block.timestamp < travelSwapEffectiveAt) revert TimelockNotElapsed();
        travelSwap = pendingTravelSwap;
        pendingTravelSwap = address(0);
        travelSwapEffectiveAt = 0;
        emit TravelSwapChanged(travelSwap);
    }

    /// Abandon a pending settlement-address proposal before it commits. Gives the admin a veto after proposing
    /// (e.g. it was a mistake) instead of being forced to let anyone `commitTravelSwap` the wrong address.
    function cancelTravelSwap() external {
        if (msg.sender != admin) revert NotAdmin();
        address was = pendingTravelSwap;
        pendingTravelSwap = address(0);
        travelSwapEffectiveAt = 0;
        emit TravelSwapProposalCanceled(was);
    }

    /// Recover USDG held ABOVE the outstanding backing — i.e. unsolicited donations (`reserve() - reserved`).
    /// Provably cannot touch backing: it sends only the surplus, so `reserve() >= reserved` is preserved.
    function skimSurplus(address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != admin) revert NotAdmin();
        if (to == address(0)) revert ZeroAddress();
        amount = reserve() - reserved; // reserve() >= reserved always, so no underflow
        if (amount == 0) revert NothingToSkim();
        usdg.safeTransfer(to, amount);
        emit SurplusSkimmed(to, amount);
    }

    // ---------------------------------------------------------------- issuance (full backing deposited up front)

    /// Mint `count` vouchers of `tier` to `to`, pulling their FULL backing (count x tierValue) from the issuer
    /// in the same call. There is no way to mint an under-backed voucher — the `reserve() >= reserved`
    /// invariant is preserved by construction. `to` is normally the Cases reserve that raffles them, and
    /// because we `_safeMint`, that reserve MUST implement `onERC721Received` or issuance to it reverts.
    function issue(uint8 tier, uint256 count, address to) external nonReentrant returns (uint256 fromId) {
        if (msg.sender != issuer) revert NotIssuer();
        if (to == address(0)) revert ZeroAddress();
        uint256 value = tierValue[tier];
        if (value == 0 || count == 0) revert BadTier();

        usdg.safeTransferFrom(msg.sender, address(this), value * count); // full backing, up front
        reserved += value * count;
        uint16 spread = sellBackSpreadBps; // lock the CURRENT spread into each voucher (see below)
        fromId = nextId;
        for (uint256 i = 0; i < count; i++) {
            uint256 id = nextId++;
            lockedValue[id] = value;
            lockedSpreadBps[id] = spread;
            voucherTier[id] = tier;
            _safeMint(to, id); // `to` is trusted (issuer-chosen), but reject a target that can't hold ERC721
        }
        emit Issued(to, tier, fromId, count, value);
    }

    // ---------------------------------------------------------------- holder exits (USDG only ever leaves here)

    /// Sell a voucher you own back for its locked value minus the house spread (the early-exit-for-cash path).
    /// The voucher burns; the spread routes to the fee sink. CEI: state is settled before any transfer.
    /// The spread is the one LOCKED at this voucher's issue, not the live `sellBackSpreadBps` — so the admin
    /// can never raise the spread to skim a holder who is already mid-exit (the front-run is impossible).
    function sellBack(uint256 id) external nonReentrant returns (uint256 paid) {
        if (ownerOf(id) != msg.sender) revert NotHolder();
        uint256 value = lockedValue[id];
        uint256 spread = (value * lockedSpreadBps[id]) / BPS;
        paid = value - spread;

        reserved -= value; // value <= reserved always: this voucher's value was added to reserved at issue
        lockedValue[id] = 0;
        lockedSpreadBps[id] = 0;
        delete voucherTier[id];
        _burn(id);

        usdg.safeTransfer(msg.sender, paid);
        if (spread != 0) usdg.safeTransfer(spreadRecipient, spread);
        emit SoldBack(id, msg.sender, paid, spread);
    }

    /// Redeem a voucher you own for the actual trip. The FULL backing is released to TravelSwap, which books
    /// the trip off-chain for you (the `Redeemed` event is the fulfilment signal; V1 books fresh, so no
    /// existing-reservation email constraint applies). The voucher burns; your claim is now off-chain.
    function redeem(uint256 id) external nonReentrant {
        address holder = ownerOf(id);
        if (holder != msg.sender) revert NotHolder();
        uint256 value = lockedValue[id];
        uint8 tier = voucherTier[id];

        reserved -= value;
        lockedValue[id] = 0;
        lockedSpreadBps[id] = 0;
        delete voucherTier[id];
        _burn(id);

        usdg.safeTransfer(travelSwap, value);
        emit Redeemed(id, holder, tier, value);
    }

    /// USDG currently held. Invariant across every state-changing call: `reserve() >= reserved`, i.e. every
    /// outstanding voucher is fully backed. Donations only ever raise reserve() above reserved, never below.
    function reserve() public view returns (uint256) {
        return usdg.balanceOf(address(this));
    }
}
