// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGameController, GameRoles} from "./GameTypes.sol";

/// GameLedger — the real-token custody core that replaces Scrip. Holds an open-ended set of RH Stock
/// Tokens (the settlement assets), tracks per-(token, account) internal balances, and moves value
/// between accounts WITHOUT ever touching a real `transfer` except at the true edges (deposit /
/// withdraw / fee). It is the money-safety heart of the game — the hardest audit target.
///
/// THE CUSTODY INVERSION (why this is not Scrip). Scrip let any registered module debit any account
/// with no approval. A real ERC-20 has no such power: value can only be PULLED with an allowance
/// (`deposit` → `transferFrom`) or reassigned once it is already inside the pool. There is NO mint and
/// NO god-debit of a player's real tokens; a module can only reshuffle what has been deposited.
///
/// SOLVENCY (the pinned invariant). For every token, `token.balanceOf(this) >= Σ effective ledgers`.
/// Deposits raise both sides; withdrawals/fees lower both; internal moves conserve. Nothing mints.
///
/// ADMINBURN TOLERANCE (the reconciler seam). A settlement stock's issuer can `adminBurn` this
/// custodian's balance mid-game. So the invariant is a `>=`, not a `==`, and a per-token survival
/// index (copied from the lending stack's CollateralReconciler) socializes any haircut pro-rata across
/// the holders present when it lands, instead of bricking withdrawals. Balances are stored INDEX-
/// NORMALIZED ("scaled"); the effective (real) balance is `scaled * index / ONE`.
///
/// SHIELDING-READY SEPARATION (the don't-rebuild decision). Accounts carry a domain. SINGLE_PARTY
/// balances (a Don's vault / banked funds) are consensual and never raidable — exactly the set that
/// can later be backed by the existing shielded-pool join-split note with zero new circuits. CONTESTED
/// balances (deployed / hopper) are raidable and stay transparent. The raid primitive (`move`) can
/// touch only CONTESTED accounts; the SINGLE_PARTY↔CONTESTED boundary is crossed only by the
/// owner-consensual `cross` (deploy / bank). This puts the privacy line exactly on the security line,
/// so shielding wires into the single-party edge later without a custody rebuild.
contract GameLedger is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Domain {
        UNSET,
        SINGLE_PARTY,
        CONTESTED
    }

    /// The survival index's "1.0": no burn yet. Monotonically non-increasing per token.
    uint256 internal constant INDEX_ONE = 1e18;

    IGameController public immutable controller;
    /// Game-local fee destination. The DonFeeRouter wiring is a post-hook-clean step (see NOTE below),
    /// so this stays a plain settable sink for now — never the shared router surface.
    address public feeSink;

    mapping(address => bool) public isToken;
    address[] public tokenList;

    /// token => account => INDEX-NORMALIZED balance. Effective balance = scaled * index / ONE.
    mapping(address => mapping(address => uint256)) public scaledOf;
    mapping(address => uint256) public totalScaled;
    mapping(address => Domain) public domainOf;

    /// token => survival index (WAD). 0 == unset (treated as INDEX_ONE) OR a total burn (terminal).
    mapping(address => uint256) public solvencyIndex;
    /// token => cumulative real units destroyed under the pool's feet, for reporting.
    mapping(address => uint256) public shortfall;
    /// token => cumulative real units routed to the fee sink (fees reach the sink, not the void).
    mapping(address => uint256) public feesRouted;

    event TokenAdded(address indexed token);
    event FeeSinkSet(address indexed sink);
    event AccountRegistered(address indexed account, Domain domain);
    event Deposited(address indexed token, address indexed account, uint256 amount);
    event Funded(address indexed token, uint256 amount);
    event Withdrawn(address indexed token, address indexed account, address indexed to, uint256 amount);
    event FeeCollected(address indexed token, address indexed account, uint256 amount);
    event Moved(address indexed token, address indexed from, address indexed to, uint256 amount);
    event Crossed(address indexed token, address indexed from, address indexed to, uint256 amount);
    event Credited(address indexed token, address indexed account, uint256 amount);
    event Debited(address indexed token, address indexed account, uint256 amount);
    event Haircut(address indexed token, uint256 oldIndex, uint256 newIndex, uint256 destroyed);

    error NotModule();
    error NotAdmin();
    error TokenNotSupported();
    error TokenAlreadySupported();
    error ZeroAddress();
    error ZeroAmount();
    error AccountUnregistered();
    error DomainImmutable();
    error NotContested();
    error NotCrossing();
    error InsufficientBalance();
    error InsufficientSurplus();
    error TokenWiped();
    error BadConfig();

    modifier onlyModule() {
        if (!controller.isModule(msg.sender)) revert NotModule();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != controller.admin()) revert NotAdmin();
        _;
    }

    constructor(IGameController controller_, address feeSink_) {
        if (address(controller_) == address(0) || feeSink_ == address(0)) revert BadConfig();
        controller = controller_;
        feeSink = feeSink_;
    }

    // ---------------------------------------------------------------- admin: token set + fee sink

    /// Register a settlement token. Open-ended by design (the House holds a growing variety of stock),
    /// but allowlisted so junk tokens cannot pollute the accounting or the solvency sweep.
    function addToken(address token) external onlyAdmin {
        if (token == address(0)) revert ZeroAddress();
        if (isToken[token]) revert TokenAlreadySupported();
        isToken[token] = true;
        solvencyIndex[token] = INDEX_ONE; // full survival until a burn ratchets it down (0 == wiped)
        tokenList.push(token);
        emit TokenAdded(token);
    }

    /// NOTE: routed to a game-local sink, NOT the shared DonFeeRouter. The DonFeeRouter integration is
    /// a deliberate post-hook-clean wiring step so the two gates do not collide on the shared surface.
    function setFeeSink(address sink) external onlyAdmin {
        if (sink == address(0)) revert ZeroAddress();
        feeSink = sink;
        emit FeeSinkSet(sink);
    }

    function tokenCount() external view returns (uint256) {
        return tokenList.length;
    }

    // ---------------------------------------------------------------- account domains

    /// Classify an account once; the domain is immutable after. The raid/pool primitives read this to
    /// keep the security line (raidable vs not) exactly on the privacy line (shieldable vs not).
    function registerAccount(address account, Domain domain) external onlyModule {
        if (account == address(0)) revert ZeroAddress();
        if (domain == Domain.UNSET) revert BadConfig();
        Domain cur = domainOf[account];
        if (cur != Domain.UNSET && cur != domain) revert DomainImmutable();
        domainOf[account] = domain;
        emit AccountRegistered(account, domain);
    }

    function _requireRegistered(address account) internal view {
        if (domainOf[account] == Domain.UNSET) revert AccountUnregistered();
    }

    // ---------------------------------------------------------------- reconciler (survival index)

    /// Live index for a supported token: INDEX_ONE at add, ratcheted down by burns, 0 only once a token
    /// has been TOTALLY burned (the terminal, un-fundable state — never custody value into wiped stock).
    function _index(address token) internal view returns (uint256) {
        return solvencyIndex[token];
    }

    /// Ratchet the index down to reflect any adminBurn discovered since the last reconcile, so total
    /// effective entitlement never exceeds the surviving balance. Monotone: index only decreases. MUST
    /// run before crediting a new deposit (so the new position snapshots the post-burn index) and
    /// before any effective balance is read for a move-out. `actual` is the balance BEFORE the pending
    /// deposit transfers in.
    function _reconcile(address token) internal {
        uint256 scaled = totalScaled[token];
        if (scaled == 0) return; // nothing to protect
        uint256 actual = IERC20(token).balanceOf(address(this));
        uint256 idx = _index(token);
        uint256 expected = (scaled * idx) / INDEX_ONE;
        if (actual >= expected) return; // no new burn
        uint256 newIdx = (actual * INDEX_ONE) / scaled; // < idx by construction
        solvencyIndex[token] = newIdx;
        uint256 destroyed = expected - actual;
        shortfall[token] += destroyed;
        emit Haircut(token, idx, newIdx, destroyed);
    }

    /// Poke the reconciler for one token (keeper/anyone). Absorbs a haircut lazily so a later op cannot
    /// mistake destroyed backing for withdrawable value.
    function sync(address token) external {
        if (!isToken[token]) revert TokenNotSupported();
        _reconcile(token);
    }

    // ---------------------------------------------------------------- conversions (rounding-safe)

    /// Real amount -> scaled units, floored: crediting slightly under-credits, safe for the pool.
    function _toScaledDown(address token, uint256 amount) internal view returns (uint256) {
        uint256 idx = _index(token);
        if (idx == 0) revert TokenWiped();
        return (amount * INDEX_ONE) / idx;
    }

    /// Real amount -> scaled units, ceiled: debiting removes slightly more, safe for the pool.
    function _toScaledUp(address token, uint256 amount) internal view returns (uint256) {
        uint256 idx = _index(token);
        if (idx == 0) revert TokenWiped();
        return (amount * INDEX_ONE + idx - 1) / idx;
    }

    // ---------------------------------------------------------------- edges (real token crosses)

    /// Pull `amount` from `payer` into `account`'s balance. The only inbound value path for a player's
    /// funds — it needs `payer`'s allowance, which is the whole point of the custody inversion: a
    /// module cannot conjure a player's real tokens, only receive what was approved.
    function deposit(address token, address payer, address account, uint256 amount)
        external
        onlyModule
        nonReentrant
    {
        if (!isToken[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        _requireRegistered(account);
        _reconcile(token);
        if (_index(token) == 0) revert TokenWiped();
        IERC20(token).safeTransferFrom(payer, address(this), amount);
        uint256 s = _toScaledDown(token, amount);
        scaledOf[token][account] += s;
        totalScaled[token] += s;
        emit Deposited(token, account, amount);
    }

    /// Pull `amount` into the pool as unallocated SURPLUS (a funded yield / stipend / prize budget),
    /// not attributed to any account. `credit` later allocates it. This is the funded-emission line:
    /// the House only ever pays out value it was actually funded with.
    function fund(address token, address payer, uint256 amount) external onlyModule nonReentrant {
        if (!isToken[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        _reconcile(token);
        if (_index(token) == 0) revert TokenWiped(); // else surplus strands: never credited, never withdrawn
        IERC20(token).safeTransferFrom(payer, address(this), amount);
        emit Funded(token, amount);
    }

    /// Debit `account` by `amount` (effective) and transfer the real token out to `to`. This is the
    /// withdrawal edge — bank() rides it. No fee, no gate here: the sacred-exit policy lives in the
    /// calling module.
    function withdraw(address token, address account, address to, uint256 amount)
        external
        onlyModule
        nonReentrant
    {
        if (!isToken[token]) revert TokenNotSupported();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _reconcile(token);
        _debitScaled(token, account, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, account, to, amount);
    }

    /// Debit `account` and route the real token to the fee sink. Every game fee (dispatch, hit-tax,
    /// repair, commit) flows through here — a real value stream, not a burn counter.
    function collectFee(address token, address account, uint256 amount) external onlyModule nonReentrant {
        if (!isToken[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        _reconcile(token);
        _debitScaled(token, account, amount);
        feesRouted[token] += amount;
        IERC20(token).safeTransfer(feeSink, amount);
        emit FeeCollected(token, account, amount);
    }

    // ---------------------------------------------------------------- internal moves (no real xfer)

    /// The contested reassignment primitive — deploy-pool, mission-loot, yield-pool, and the raid. It
    /// can touch ONLY contested accounts, so a raid can never reach a single-party vault. Conserves
    /// effective total exactly (moves scaled units 1:1).
    function move(address token, address from, address to, uint256 amount) external onlyModule nonReentrant {
        if (!isToken[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        if (domainOf[from] != Domain.CONTESTED || domainOf[to] != Domain.CONTESTED) revert NotContested();
        _reconcile(token);
        uint256 s = _toScaledDown(token, amount);
        uint256 bal = scaledOf[token][from];
        if (bal < s) revert InsufficientBalance();
        unchecked {
            scaledOf[token][from] = bal - s;
        }
        scaledOf[token][to] += s;
        emit Moved(token, from, to, amount);
    }

    /// The consensual boundary bridge — exactly one single-party and one contested endpoint (deploy:
    /// vault -> deployed; bank: hopper/deployed -> vault). The calling module enforces owner consent;
    /// this only enforces that the boundary is crossed, never breached by a raid.
    function cross(address token, address from, address to, uint256 amount) external onlyModule nonReentrant {
        if (!isToken[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        if (!_isCrossing(from, to)) revert NotCrossing();
        _reconcile(token);
        uint256 s = _toScaledDown(token, amount);
        uint256 bal = scaledOf[token][from];
        if (bal < s) revert InsufficientBalance();
        unchecked {
            scaledOf[token][from] = bal - s;
        }
        scaledOf[token][to] += s;
        emit Crossed(token, from, to, amount);
    }

    function _isCrossing(address a, address b) internal view returns (bool) {
        Domain da = domainOf[a];
        Domain db = domainOf[b];
        return (da == Domain.SINGLE_PARTY && db == Domain.CONTESTED)
            || (da == Domain.CONTESTED && db == Domain.SINGLE_PARTY);
    }

    /// Allocate `amount` of pool SURPLUS into `account` (mission loot / yield / stipend land here from
    /// the funded budget). Guarded by the surplus check so a credit can NEVER exceed the real tokens
    /// actually present — this is what keeps the solvency `>=` true. Removing that check is the mutation
    /// the solvency test pins.
    function credit(address token, address account, uint256 amount) external onlyModule nonReentrant {
        if (!isToken[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        _requireRegistered(account);
        _reconcile(token);
        if (amount > _surplus(token)) revert InsufficientSurplus();
        uint256 s = _toScaledDown(token, amount);
        scaledOf[token][account] += s;
        totalScaled[token] += s;
        emit Credited(token, account, amount);
    }

    /// Deallocate `amount` from `account` back into pool surplus (a consumed provision / commit stake
    /// becomes the House's retained bankroll — the real-token form of a Scrip stake-burn). No token
    /// leaves; it simply stops being attributed to a player.
    function debit(address token, address account, uint256 amount) external onlyModule nonReentrant {
        if (!isToken[token]) revert TokenNotSupported();
        if (amount == 0) revert ZeroAmount();
        _reconcile(token);
        _debitScaled(token, account, amount);
        emit Debited(token, account, amount);
    }

    function _debitScaled(address token, address account, uint256 amount) internal {
        if (amount > effectiveBalanceOf(token, account)) revert InsufficientBalance();
        uint256 s = _toScaledUp(token, amount);
        uint256 bal = scaledOf[token][account];
        if (s > bal) s = bal; // ceil never removes more scaled than exists
        unchecked {
            scaledOf[token][account] = bal - s;
        }
        totalScaled[token] -= s;
    }

    // ---------------------------------------------------------------- views

    /// Effective (real-token) balance of an account, net of any survived haircut.
    function effectiveBalanceOf(address token, address account) public view returns (uint256) {
        return (scaledOf[token][account] * _index(token)) / INDEX_ONE;
    }

    /// Total effective entitlement across all accounts of a token — the right side of the solvency law.
    function effectiveTotalOf(address token) public view returns (uint256) {
        return (totalScaled[token] * _index(token)) / INDEX_ONE;
    }

    /// Unallocated real tokens: what `credit` may draw and where consumed stakes accumulate.
    function surplusOf(address token) external view returns (uint256) {
        return _surplus(token);
    }

    function _surplus(address token) internal view returns (uint256) {
        uint256 actual = IERC20(token).balanceOf(address(this));
        uint256 owed = effectiveTotalOf(token);
        return actual > owed ? actual - owed : 0;
    }

    /// The pinned solvency check, exposed for the invariant harness and keepers: real balance covers
    /// every effective ledger. Holds by construction pre-burn and after any `sync`/reconcile post-burn.
    function isSolvent(address token) external view returns (bool) {
        return IERC20(token).balanceOf(address(this)) >= effectiveTotalOf(token);
    }

    // ---------------------------------------------------------------- SHIELDING SEAM (wire-in later)
    //
    // The single-party balance set (domainOf == SINGLE_PARTY) is the exact, and only, set that can be
    // backed by the existing shielded-pool join-split note — every move of it is consensual and single-
    // party, so it rides `transaction2` with ZERO new circuits (see SHIELDED-GAME-REUSE-VS-BUILD §5).
    // A later phase backs it by routing a single-party withdraw into `pool.transact(deposit)` and an
    // unshield back into a single-party credit; contested balances are never touched. No shielding is
    // built here — this comment marks the wire-in point that the clean domain split makes possible.
}
