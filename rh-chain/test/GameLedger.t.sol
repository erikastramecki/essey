// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GameLedger} from "../src/game/GameLedger.sol";
import {IGameController, GameRoles} from "../src/game/GameTypes.sol";

/// A tokenized-stock token carrying the Robinhood Stock Token hazard: an arbitrary-address `adminBurn`
/// the issuer can call to destroy tokens at ANY holder, the custodian included. Decimals are a ctor arg
/// so the same suite exercises the 6-dec (USDG) and 18-dec (stock) footgun (rework §3.2).
contract BurnableStock is ERC20 {
    uint8 private immutable _dec;

    constructor(uint8 dec_) ERC20("Robinhood Stock", "STK") {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function adminBurn(address from, uint256 amt) external {
        _burn(from, amt); // the whole hazard: the issuer can burn anyone's balance
    }
}

/// Minimal controller stub: the ledger asks only admin / isModule / moduleOf / closed.
contract MockController is IGameController {
    address public admin;
    bool public closed;
    mapping(address => bool) public isModule;
    mapping(bytes32 => address) public moduleOf;

    constructor(address admin_) {
        admin = admin_;
    }

    function setModule(address m, bool on) external {
        isModule[m] = on;
    }

    function setRole(bytes32 role, address m) external {
        moduleOf[role] = m;
        isModule[m] = true;
    }
}

contract GameLedgerTest is Test {
    GameLedger ledger;
    MockController controller;
    BurnableStock stk; // 18-dec
    BurnableStock usdg; // 6-dec

    address admin = address(0xA11CE);
    address module = address(0x510D); // the single test "module"
    address feeSink = address(0xFEE5);
    address player = address(0x1111);

    function setUp() public {
        controller = new MockController(admin);
        vm.prank(admin);
        ledger = new GameLedger(IGameController(address(controller)), feeSink);
        controller.setModule(module, true);

        stk = new BurnableStock(18);
        usdg = new BurnableStock(6);
        vm.startPrank(admin);
        ledger.addToken(address(stk));
        ledger.addToken(address(usdg));
        vm.stopPrank();

        // register the canonical account taxonomy this suite uses
        vm.startPrank(module);
        ledger.registerAccount(_vaultA(), GameLedger.Domain.SINGLE_PARTY);
        ledger.registerAccount(_vaultB(), GameLedger.Domain.SINGLE_PARTY);
        ledger.registerAccount(_deployed(), GameLedger.Domain.CONTESTED);
        ledger.registerAccount(_hopper(), GameLedger.Domain.CONTESTED);
        ledger.registerAccount(_hopperB(), GameLedger.Domain.CONTESTED);
        vm.stopPrank();
    }

    function _vaultA() internal pure returns (address) {
        return address(0xAA01);
    }

    function _vaultB() internal pure returns (address) {
        return address(0xAA02);
    }

    function _deployed() internal pure returns (address) {
        return address(0xC001);
    }

    function _hopper() internal pure returns (address) {
        return address(0xC002);
    }

    function _hopperB() internal pure returns (address) {
        return address(0xC003);
    }

    // fund the ledger for `account` with `amt` of `token`, via the deposit edge
    function _seed(BurnableStock token, address account, uint256 amt) internal {
        token.mint(player, amt);
        vm.prank(player);
        token.approve(address(ledger), amt);
        vm.prank(module);
        ledger.deposit(address(token), player, account, amt);
    }

    // ---------------------------------------------------------------- custody inversion

    function test_deposit_requiresAllowance_noGodPull() public {
        stk.mint(player, 100e18);
        // no approve -> the custodian cannot conjure the player's tokens
        vm.prank(module);
        vm.expectRevert();
        ledger.deposit(address(stk), player, _vaultA(), 100e18);
    }

    function test_deposit_creditsExactly_indexOne() public {
        _seed(stk, _vaultA(), 100e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _vaultA()), 100e18);
        assertEq(stk.balanceOf(address(ledger)), 100e18);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    // onlyModule fires at the modifier, ahead of every in-body arg/state check, so a non-module caller
    // is rejected on well-typed args alone. One assert per value path: dropping onlyModule from any one
    // lets its call fall through to a body that reverts with a DIFFERENT selector (or not at all),
    // failing the exact-selector expectRevert. Registration is pinned separately below.
    function test_onlyModule_gatesValuePaths() public {
        stk.mint(player, 1e18);
        vm.prank(player);
        stk.approve(address(ledger), 1e18);

        vm.startPrank(player); // not a module
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.deposit(address(stk), player, _vaultA(), 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.fund(address(stk), player, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.withdraw(address(stk), _vaultA(), player, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.collectFee(address(stk), _vaultA(), 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.move(address(stk), _deployed(), _hopper(), 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.cross(address(stk), _vaultA(), _deployed(), 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.credit(address(stk), _hopper(), 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.debit(address(stk), _hopper(), 1e18);
        vm.stopPrank();
    }

    function test_onlyModule_gatesRegistration() public {
        vm.prank(player); // not a module
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.registerAccount(address(0x9999), GameLedger.Domain.SINGLE_PARTY);
    }

    function test_onlyAdmin_gatesTokenAndSink() public {
        vm.prank(player);
        vm.expectRevert(GameLedger.NotAdmin.selector);
        ledger.addToken(address(0xdead));
        vm.prank(player);
        vm.expectRevert(GameLedger.NotAdmin.selector);
        ledger.setFeeSink(address(0xbeef));
    }

    // ---------------------------------------------------------------- registration / domains

    function test_unregisteredAccount_cannotReceive() public {
        stk.mint(player, 1e18);
        vm.prank(player);
        stk.approve(address(ledger), 1e18);
        vm.prank(module);
        vm.expectRevert(GameLedger.AccountUnregistered.selector);
        ledger.deposit(address(stk), player, address(0xBADBAD), 1e18);
    }

    function test_domain_isImmutable() public {
        vm.prank(module);
        vm.expectRevert(GameLedger.DomainImmutable.selector);
        ledger.registerAccount(_vaultA(), GameLedger.Domain.CONTESTED);
    }

    // ---------------------------------------------------------------- solvency (the pinned law)

    function test_credit_beyondSurplus_reverts() public {
        // no surplus funded -> a credit that would appear from nothing must revert
        vm.prank(module);
        vm.expectRevert(GameLedger.InsufficientSurplus.selector);
        ledger.credit(address(stk), _hopper(), 1e18);
    }

    function test_credit_fromFundedSurplus_ok() public {
        // fund the pool as unattributed surplus, then allocate it (the yield/loot path)
        stk.mint(player, 50e18);
        vm.prank(player);
        stk.approve(address(ledger), 50e18);
        vm.prank(module);
        ledger.fund(address(stk), player, 50e18);
        assertEq(ledger.surplusOf(address(stk)), 50e18);

        vm.prank(module);
        ledger.credit(address(stk), _hopper(), 30e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 30e18);
        assertEq(ledger.surplusOf(address(stk)), 20e18);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    /// Pins the credit surplus-guard BOUNDARY: `amount > surplus`, NOT `>=`. Crediting the EXACT full
    /// funded surplus must succeed and drain surplus to zero. A `>`->`>=` regression would revert here,
    /// stranding the last unit of a funded prize/loot budget as un-allocatable dust. The other credit
    /// tests credit 30 of 50 or 0 of 0, so this exact-surplus boundary was unpinned (mutation lens R2).
    function test_credit_exactFullSurplus_ok() public {
        stk.mint(player, 50e18);
        vm.prank(player);
        stk.approve(address(ledger), 50e18);
        vm.prank(module);
        ledger.fund(address(stk), player, 50e18);
        assertEq(ledger.surplusOf(address(stk)), 50e18);

        vm.prank(module);
        ledger.credit(address(stk), _hopper(), 50e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 50e18);
        assertEq(ledger.surplusOf(address(stk)), 0);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    /// fund's _reconcile-before-transferFrom (:231), same masking class as the post-burn deposit pin. A
    /// burn is left UNSYNCED, then the House funds surplus. Reconcile must lock in the haircut BEFORE the
    /// funding's real tokens can mask it — otherwise the shortfall vanishes and the pre-burn holder is
    /// silently un-haircut at the House's expense. Pins reconcile removal from fund.
    function test_fund_afterUnsyncedBurn_locksHaircutBeforeMasking() public {
        _seed(stk, _hopper(), 100e18);
        stk.adminBurn(address(ledger), 40e18); // 60 survives, index should fall to 0.6, NOT synced

        stk.mint(player, 40e18);
        vm.prank(player);
        stk.approve(address(ledger), 40e18);
        vm.prank(module);
        ledger.fund(address(stk), player, 40e18); // funding must NOT retroactively cover the burn
        ledger.sync(address(stk));

        assertEq(ledger.shortfall(address(stk)), 40e18); // the burn is recorded, not masked away
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 60e18); // holder stays haircut
        assertEq(ledger.surplusOf(address(stk)), 40e18); // funding is pure surplus, not a back-fill
        assertTrue(ledger.isSolvent(address(stk)));
    }

    // ---------------------------------------------------------------- raids never mint / conservation

    function test_move_conservesTotal() public {
        _seed(stk, _deployed(), 100e18);
        uint256 before = ledger.effectiveTotalOf(address(stk));
        vm.prank(module);
        ledger.move(address(stk), _deployed(), _hopper(), 40e18);
        assertEq(ledger.effectiveTotalOf(address(stk)), before); // nothing minted, nothing burned
        assertEq(ledger.effectiveBalanceOf(address(stk), _deployed()), 60e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 40e18);
        assertTrue(ledger.isSolvent(address(stk)));

        // exact-full-balance move (bal == s): the `bal < s` boundary must let a whole balance leave and
        // zero the source. A `<`→`<=` mutant reverts here (F3).
        vm.prank(module);
        ledger.move(address(stk), _deployed(), _hopper(), 60e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _deployed()), 0);
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 100e18);
        assertEq(ledger.effectiveTotalOf(address(stk)), before);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    function test_move_rejectsSingleParty_raidCannotTouchVault() public {
        _seed(stk, _vaultA(), 100e18);
        // a raid (move) can never name a single-party vault as source
        vm.prank(module);
        vm.expectRevert(GameLedger.NotContested.selector);
        ledger.move(address(stk), _vaultA(), _deployed(), 10e18);
        // ...nor as destination
        _seed(stk, _deployed(), 10e18);
        vm.prank(module);
        vm.expectRevert(GameLedger.NotContested.selector);
        ledger.move(address(stk), _deployed(), _vaultA(), 10e18);
    }

    /// move's _reconcile-before-read (:274). A raid at a STALE index must still deliver the requested
    /// EFFECTIVE amount: without the reconcile it moves nominal scaled units, so a pending haircut lands
    /// unevenly and the recipient ends short (40e18 -> 20e18). Pins reconcile removal from move.
    function test_move_afterUnsyncedBurn_deliversEffectiveAmount() public {
        _seed(stk, _deployed(), 100e18);
        stk.adminBurn(address(ledger), 50e18); // index should fall to 0.5, deliberately NOT synced
        vm.prank(module);
        ledger.move(address(stk), _deployed(), _hopper(), 40e18); // 40 EFFECTIVE
        ledger.sync(address(stk));
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 40e18); // recipient got full effective
        assertEq(ledger.effectiveBalanceOf(address(stk), _deployed()), 10e18); // 50 survived - 40 moved
        assertTrue(ledger.isSolvent(address(stk)));
    }

    // ---------------------------------------------------------------- cross (consensual boundary)

    function test_cross_bridgesBoundary_bothDirections() public {
        _seed(stk, _vaultA(), 100e18);
        // deploy: single -> contested
        vm.prank(module);
        ledger.cross(address(stk), _vaultA(), _deployed(), 60e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _deployed()), 60e18);
        // bank: contested -> single
        vm.prank(module);
        ledger.cross(address(stk), _deployed(), _vaultA(), 20e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _vaultA()), 60e18);
        assertEq(ledger.effectiveTotalOf(address(stk)), 100e18);

        // exact-full-balance cross (bal == s): the `bal < s` boundary must let the whole remaining
        // deployed balance bank back and zero the source. A `<`→`<=` mutant reverts here (F3).
        vm.prank(module);
        ledger.cross(address(stk), _deployed(), _vaultA(), 40e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _deployed()), 0);
        assertEq(ledger.effectiveBalanceOf(address(stk), _vaultA()), 100e18);
        assertEq(ledger.effectiveTotalOf(address(stk)), 100e18);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    function test_cross_rejectsSameDomain() public {
        _seed(stk, _deployed(), 10e18);
        vm.prank(module);
        vm.expectRevert(GameLedger.NotCrossing.selector); // both contested
        ledger.cross(address(stk), _deployed(), _hopper(), 5e18);
        _seed(stk, _vaultA(), 10e18);
        vm.prank(module);
        vm.expectRevert(GameLedger.NotCrossing.selector); // both single-party
        ledger.cross(address(stk), _vaultA(), _vaultB(), 5e18);
    }

    /// cross's _reconcile-before-read (:292), sibling of the move pin. A consensual bridge at a stale
    /// index must still deliver the requested EFFECTIVE amount across the boundary. Pins reconcile
    /// removal from cross.
    function test_cross_afterUnsyncedBurn_deliversEffectiveAmount() public {
        _seed(stk, _vaultA(), 100e18);
        stk.adminBurn(address(ledger), 50e18); // NOT synced
        vm.prank(module);
        ledger.cross(address(stk), _vaultA(), _deployed(), 40e18); // 40 EFFECTIVE, single -> contested
        ledger.sync(address(stk));
        assertEq(ledger.effectiveBalanceOf(address(stk), _deployed()), 40e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _vaultA()), 10e18);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    // ---------------------------------------------------------------- withdraw (the exit) + fees

    function test_withdraw_exit_transfersFullAmount() public {
        _seed(stk, _vaultA(), 100e18);
        vm.prank(module);
        ledger.withdraw(address(stk), _vaultA(), player, 40e18);
        assertEq(stk.balanceOf(player), 40e18); // no skim, no fee on the exit edge
        assertEq(ledger.effectiveBalanceOf(address(stk), _vaultA()), 60e18);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    function test_collectFee_reachesSink() public {
        _seed(stk, _vaultA(), 100e18);
        vm.prank(module);
        ledger.collectFee(address(stk), _vaultA(), 10e18);
        assertEq(stk.balanceOf(feeSink), 10e18);
        assertEq(ledger.feesRouted(address(stk)), 10e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _vaultA()), 90e18);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    /// F1 (ordering): collectFee MUST _reconcile BEFORE _debitScaled. Two contested co-holders, a raw
    /// adminBurn left UNSYNCED, then a fee is pulled from A at the stale index. If reconcile ran AFTER
    /// the debit, A's fee shrinks the scaled base the pending haircut is later socialized over, so the
    /// burn is amplified onto co-holder B — robbing B from its fair pro-rata share (~28e18) down to
    /// ~16e18. fairB is computed from the pre-fee state so the mutated index can't launder the check.
    function test_collectFee_afterUnsyncedBurn_cannotRobOtherHolder() public {
        _seed(stk, _hopper(), 160e18); // A
        _seed(stk, _hopperB(), 40e18); // B — total 200e18, two contested holders
        stk.adminBurn(address(ledger), 60e18 + 3); // ragged non-divisor, deliberately NOT synced

        uint256 fairB = _fairShare(_hopperB()); // B's share of ONLY the burn, over the full pre-op base

        vm.prank(module);
        ledger.collectFee(address(stk), _hopper(), 100e18); // fee from A at the stale index
        ledger.sync(address(stk));

        assertEq(ledger.effectiveBalanceOf(address(stk), _hopperB()), fairB); // not robbed
        assertTrue(ledger.isSolvent(address(stk)));
    }

    /// F2 (ordering): debit MUST _reconcile before _debitScaled, same class as F1. A debit at the stale
    /// index mis-socializes a pending haircut (the deallocated face masks the burn instead of the pool
    /// sharing it pro-rata), so co-holder B drifts off its fair value. fairB is pinned from pre-op state.
    function test_debit_afterUnsyncedBurn_cannotRobOtherHolder() public {
        _seed(stk, _hopper(), 160e18); // A
        _seed(stk, _hopperB(), 40e18); // B
        stk.adminBurn(address(ledger), 60e18 + 3); // ragged, NOT synced

        uint256 fairB = _fairShare(_hopperB());

        vm.prank(module);
        ledger.debit(address(stk), _hopper(), 100e18); // debit at the stale index
        ledger.sync(address(stk));

        assertEq(ledger.effectiveBalanceOf(address(stk), _hopperB()), fairB);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    // B's fair effective share = its scaled units at the index that reflects ONLY the discovered burn,
    // socialized over the FULL pre-op scaled base. Reading it before the op under test keeps the
    // expectation independent of any index the mutant later computes.
    function _fairShare(address account) internal view returns (uint256) {
        uint256 realNow = stk.balanceOf(address(ledger));
        uint256 totalScaled = ledger.totalScaled(address(stk));
        uint256 fairIdx = (realNow * 1e18) / totalScaled;
        return (ledger.scaledOf(address(stk), account) * fairIdx) / 1e18;
    }

    // ---------------------------------------------------------------- debit -> house surplus

    function test_debit_deallocatesToSurplus() public {
        _seed(stk, _deployed(), 100e18);
        vm.prank(module);
        ledger.debit(address(stk), _deployed(), 30e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _deployed()), 70e18);
        assertEq(ledger.surplusOf(address(stk)), 30e18); // stays in custody as house bankroll
        assertEq(stk.balanceOf(address(ledger)), 100e18); // no token left the pool
        assertTrue(ledger.isSolvent(address(stk)));
    }

    // ---------------------------------------------------------------- decimals-agnostic (§3.2)

    function test_decimalsAgnostic_6decAnd18dec_roundTrip() public {
        // 18-dec stock
        _seed(stk, _vaultA(), 123e18);
        vm.prank(module);
        ledger.withdraw(address(stk), _vaultA(), player, 123e18);
        assertEq(stk.balanceOf(player), 123e18);

        // 6-dec USDG through the exact same code path — no 18-dec assumption anywhere
        _seed(usdg, _vaultB(), 123e6);
        assertEq(ledger.effectiveBalanceOf(address(usdg), _vaultB()), 123e6);
        vm.prank(module);
        ledger.withdraw(address(usdg), _vaultB(), player, 123e6);
        assertEq(usdg.balanceOf(player), 123e6);
        assertTrue(ledger.isSolvent(address(usdg)));
    }

    // ---------------------------------------------------------------- adminBurn reconciler seam

    function test_adminBurn_partial_socializesHaircut_noBrick() public {
        _seed(stk, _hopper(), 60e18);
        _seed(stk, _hopperB(), 40e18); // total 100, two contested holders
        assertTrue(ledger.isSolvent(address(stk)));

        // issuer destroys 50% of the custodian's balance mid-game
        stk.adminBurn(address(ledger), 50e18);
        // pre-sync the raw view is stale; the reconciler absorbs the haircut
        ledger.sync(address(stk));

        assertTrue(ledger.isSolvent(address(stk))); // NOT bricked
        // pro-rata: each holder keeps half
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 30e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopperB()), 20e18);
        assertEq(ledger.effectiveTotalOf(address(stk)), 50e18);
        assertEq(ledger.shortfall(address(stk)), 50e18);

        // a holder can still exit their survived share
        vm.prank(module);
        ledger.withdraw(address(stk), _hopper(), player, 30e18);
        assertEq(stk.balanceOf(player), 30e18);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    function test_adminBurn_reconcileIsLazy_withdrawSelfHeals() public {
        _seed(stk, _hopper(), 100e18);
        stk.adminBurn(address(ledger), 40e18); // 60 survives
        // without an explicit sync, the next value op reconciles first
        vm.prank(module);
        ledger.withdraw(address(stk), _hopper(), player, 60e18);
        assertEq(stk.balanceOf(player), 60e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 0);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    function test_adminBurn_total_terminalWiped() public {
        _seed(stk, _hopper(), 100e18);
        stk.adminBurn(address(ledger), 100e18);
        ledger.sync(address(stk));
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 0);
        assertTrue(ledger.isSolvent(address(stk))); // 0 >= 0
        // cannot custody new value into a fully-destroyed token
        stk.mint(player, 10e18);
        vm.prank(player);
        stk.approve(address(ledger), 10e18);
        vm.prank(module);
        vm.expectRevert(GameLedger.TokenWiped.selector);
        ledger.deposit(address(stk), player, _hopper(), 10e18);
    }

    /// Sibling of the deposit-side wiped pin: fund() must ALSO reject an index-0 token. Without the
    /// guard the pull succeeds but the surplus is unreachable — credit()'s _toScaledDown reverts
    /// TokenWiped and no scaled balance exists to withdraw, so the real tokens strand permanently.
    function test_fund_intoWipedToken_reverts() public {
        _seed(stk, _hopper(), 100e18);
        stk.adminBurn(address(ledger), 100e18); // index -> 0
        ledger.sync(address(stk));
        stk.mint(player, 10e18);
        vm.prank(player);
        stk.approve(address(ledger), 10e18);
        vm.prank(module);
        vm.expectRevert(GameLedger.TokenWiped.selector);
        ledger.fund(address(stk), player, 10e18);
    }

    function test_adminBurn_insulatesPostBurnDepositor() public {
        _seed(stk, _hopper(), 100e18);
        stk.adminBurn(address(ledger), 50e18); // old holder haircut to 50
        ledger.sync(address(stk));
        // a fresh deposit AFTER the burn snapshots the lowered index and recovers full value
        _seed(stk, _hopperB(), 80e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopperB()), 80e18); // insulated
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 50e18); // still haircut
        assertTrue(ledger.isSolvent(address(stk)));
    }

    /// The reconcile-before-credit ordering, isolated. A fresh depositor lands AFTER a raw adminBurn
    /// with NO explicit sync: deposit() must reconcile first, so the newcomer snapshots the lowered
    /// index and keeps full value while the pre-burn holder alone eats the haircut. The insulation test
    /// above syncs first, which masks a mutant that runs _reconcile AFTER the transferFrom — there the
    /// newcomer's own deposit hides the burn and everyone is credited at the stale ONE index, breaking
    /// solvency.
    function test_adminBurn_postBurnDeposit_lazyReconcile_noSync() public {
        _seed(stk, _hopper(), 100e18);
        stk.adminBurn(address(ledger), 37e18); // ragged: index -> 0.63e18, and deliberately NOT synced

        _seed(stk, _hopperB(), 50e18); // this deposit must itself trigger the reconcile

        assertTrue(ledger.isSolvent(address(stk)));
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 63e18); // pre-burn holder ate it all
        assertApproxEqAbs(ledger.effectiveBalanceOf(address(stk), _hopperB()), 50e18, 2); // newcomer whole
    }

    /// COMPOUNDING (M9): two sequential burns while the index is ALREADY below ONE. The reconciler's
    /// newIdx must be `actual*ONE/scaled` (absolute), NOT `actual*idx/scaled` (which re-multiplies the
    /// already-applied haircut and buries surviving value as un-owned surplus). Every other adminBurn
    /// test burns exactly once, so reconcile only ever runs at idx==ONE where the two forms coincide;
    /// this is the sole witness that separates them. The intermediate sync is load-bearing: it drops the
    /// index to 0.6 so the SECOND reconcile compounds. A burn reconcile with no funded/debited surplus
    /// must strand nothing — every surviving unit stays owned, so effTotal == real backing exactly.
    /// Mutant (:173 actual*idx/scaled): idx->0.18 not 0.3, holder 18e18 not 30e18, 12e18 stranded.
    function test_reconcile_twoSequentialBurns_strandsNothing() public {
        _seed(stk, _hopper(), 100e18);
        stk.adminBurn(address(ledger), 40e18);
        ledger.sync(address(stk)); // index -> 0.6 while at ONE; the second burn compounds off THIS
        stk.adminBurn(address(ledger), 30e18);
        ledger.sync(address(stk)); // second reconcile runs at idx 0.6, not ONE

        assertEq(ledger.effectiveTotalOf(address(stk)), stk.balanceOf(address(ledger))); // == 30e18, strands 0
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 30e18);
        assertTrue(ledger.isSolvent(address(stk)));
    }

    /// COMPOUNDING, multi-holder: the incremental loss of a SECOND sub-ONE burn must socialize pro-rata
    /// across every present holder, not strand it. Two holders 70/30; burns 37e18 then 21e18 leave 42e18
    /// real, and each holder must end at its share of ONLY that surviving 42e18 (29.4 / 12.6), with
    /// effTotal == real backing. Same witness class as above: the mutant's compounded index drops both
    /// holders far below their pro-rata (18.522 / 7.938) and effTotal to 26.46e18 != 42e18.
    function test_reconcile_twoSequentialBurns_multiHolder_socializesPropRata() public {
        _seed(stk, _hopper(), 70e18);
        _seed(stk, _hopperB(), 30e18); // total 100e18, two contested co-holders
        stk.adminBurn(address(ledger), 37e18);
        ledger.sync(address(stk)); // index -> 0.63 (ragged, non-round)
        stk.adminBurn(address(ledger), 21e18);
        ledger.sync(address(stk)); // second reconcile compounds off 0.63

        uint256 realNow = stk.balanceOf(address(ledger)); // 42e18 survived
        assertEq(ledger.effectiveTotalOf(address(stk)), realNow); // strands nothing
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 29_400_000_000_000_000_000); // 70% of 42e18
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopperB()), 12_600_000_000_000_000_000); // 30% of 42e18
        assertTrue(ledger.isSolvent(address(stk)));
    }

    /// A hand-picked ragged burn (777_777 of 1_333_333 -> a non-divisor index) drives credit / debit /
    /// withdraw through the floor-in / ceil-out conversions without fuzzing. Every step re-asserts the
    /// pinned solvency law and that effective entitlement never exceeds the surviving backing.
    function test_adminBurn_raggedIndex_creditDebitWithdraw_staysSolvent() public {
        _seed(stk, _hopper(), 1_333_333);
        stk.adminBurn(address(ledger), 777_777); // 555_556 survives; the index is a non-divisor
        ledger.sync(address(stk));

        uint256 idx = ledger.solvencyIndex(address(stk));
        assertTrue(idx < 1e18 && idx > 0); // ragged, non-terminal
        assertEq(ledger.shortfall(address(stk)), 777_777);
        assertTrue(ledger.isSolvent(address(stk)));
        assertLe(ledger.effectiveBalanceOf(address(stk), _hopper()), 555_556);
        assertLe(ledger.effectiveTotalOf(address(stk)), stk.balanceOf(address(ledger)));

        // credit from funded surplus at the ragged index — floor-in never over-credits the newcomer
        stk.mint(player, 400_000);
        vm.prank(player);
        stk.approve(address(ledger), 400_000);
        vm.prank(module);
        ledger.fund(address(stk), player, 400_000);
        vm.prank(module);
        ledger.credit(address(stk), _hopperB(), 400_000);
        assertLe(ledger.effectiveBalanceOf(address(stk), _hopperB()), 400_000);
        assertTrue(ledger.isSolvent(address(stk)));

        // debit back to surplus at the ragged index — ceil-out removes at least face
        vm.prank(module);
        ledger.debit(address(stk), _hopperB(), 150_000);
        assertTrue(ledger.isSolvent(address(stk)));

        // withdraw the surviving hopper balance out; the exit edge transfers exactly and stays solvent
        uint256 exit = ledger.effectiveBalanceOf(address(stk), _hopper());
        vm.prank(module);
        ledger.withdraw(address(stk), _hopper(), player, exit);
        assertEq(stk.balanceOf(player), exit);
        assertTrue(ledger.isSolvent(address(stk)));
        assertEq(ledger.effectiveBalanceOf(address(stk), _hopper()), 0); // ceil + cap fully drains it
    }

    // ---------------------------------------------------------------- token allowlist

    function test_unsupportedToken_rejected() public {
        BurnableStock rogue = new BurnableStock(18);
        rogue.mint(player, 1e18);
        vm.prank(player);
        rogue.approve(address(ledger), 1e18);
        vm.prank(module);
        vm.expectRevert(GameLedger.TokenNotSupported.selector);
        ledger.deposit(address(rogue), player, _vaultA(), 1e18);
    }

    function test_addToken_noDuplicate() public {
        vm.prank(admin);
        vm.expectRevert(GameLedger.TokenAlreadySupported.selector);
        ledger.addToken(address(stk));
    }
}
