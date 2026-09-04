// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {MockUSDG} from "./EsseyPool.t.sol";
import {Note} from "../src/market/Note.sol";
import {NoteArt} from "../src/market/NoteArt.sol";
import {PoolFactory} from "../src/market/PoolFactory.sol";

/// F1 (round 6): the registry MIRRORS markets.activePool — the timelocked authority — instead of
/// the old first-come-forever slot that made a same-token successor undiscoverable.
contract PoolFactoryTest is Test {
    EsseyMarkets mk;
    PoolFactory factory;
    MockUSDG usdg;
    MockStock tok;
    MockFeed px;

    address ADMIN;
    address TREASURY;

    uint256 constant MON_IN_SESSION = 1_753_110_000;

    function setUp() public {
        ADMIN = makeAddr("admin");
        TREASURY = makeAddr("treasury");
        vm.warp(MON_IN_SESSION);
        mk = _newMarkets(ADMIN);
        usdg = new MockUSDG();
        tok = new MockStock();
        px = new MockFeed(200e8, 8);
        factory = new PoolFactory(mk);
    }

    function _newMarkets(address admin) internal returns (EsseyMarkets) {
        MockFeed seq = new MockFeed(0, 0);
        seq.setStartedAt(block.timestamp - 2 days);
        LivenessOracle liv =
            new LivenessOracle(makeAddr("keeper"), makeAddr("guardian"), makeAddr("livenessRotator"), 10 minutes, 30 minutes);
        MarketHealthOracle hox = new MarketHealthOracle(makeAddr("keeper"), makeAddr("guardian"), admin);
        EsseyMarkets m = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, admin, makeAddr("mk-guardian"), 6);
        vm.prank(admin);
        hox.wireMarkets(address(m));
        return m;
    }

    function _identity(string memory sym) internal pure returns (EsseyPool.Identity memory) {
        return EsseyPool.Identity(
            string.concat("Essey ", sym, " Pool Share"), string.concat("a", sym),
            string.concat("Essey ", sym, " Note"), string.concat("n", sym)
        );
    }

    /// Deploy + wire the way the deploy script now does; this test contract is the deployer.
    function _wiredPool(address token, EsseyMarkets markets) internal returns (EsseyPool pool) {
        pool = new EsseyPool(usdg, token, markets, 0, 0, 0, 0, address(0), TREASURY, 0, _identity("AAPL"));
        pool.setNoteArt(address(new NoteArt(pool, pool.note())));
    }

    /// Make `pool` the token's activePool through the real pipeline — register's precondition.
    function _commitAsActive(address token, EsseyPool pool) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
        vm.prank(ADMIN);
        mk.proposeMarket(token, AggregatorV3Interface(address(px)), 86_400, 90_000, 8, token, address(pool), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(token);
    }

    function _register(address token) internal returns (EsseyPool pool) {
        pool = _wiredPool(token, mk);
        _commitAsActive(token, pool);
        vm.prank(ADMIN);
        factory.register(token, address(pool));
    }

    function test_registerRecordsThePool() public {
        EsseyPool pool = _register(address(tok));
        assertEq(factory.poolFor(address(tok)), address(pool));
    }

    /// note/art are DERIVED from the pool, not passed — the exact addresses must land in the event.
    function test_registerEmitsPoolDeployed() public {
        EsseyPool pool = _wiredPool(address(tok), mk);
        _commitAsActive(address(tok), pool);
        vm.expectEmit(true, true, false, true, address(factory));
        emit PoolFactory.PoolDeployed(address(tok), address(pool), address(pool.note()), pool.note().art());
        vm.prank(ADMIN);
        factory.register(address(tok), address(pool));
    }

    /// The mirror rule itself: anything that is not the CURRENT activePool is refused, so the
    /// registry can never point at a pool the timelocked pipeline did not install.
    function test_registerRefusesAPoolThatIsNotActive() public {
        EsseyPool active = _register(address(tok));
        EsseyPool other = _wiredPool(address(tok), mk);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(PoolFactory.NotActivePool.selector, address(tok), address(active), address(other))
        );
        factory.register(address(tok), address(other));
    }

    /// Idempotent by choice: re-registering the current active pool succeeds and RE-EMITS
    /// PoolDeployed — a keeper that missed the first log can be replayed into discovery.
    function test_reRegisteringTheActivePoolReEmits() public {
        EsseyPool pool = _register(address(tok));
        vm.expectEmit(true, true, false, true, address(factory));
        emit PoolFactory.PoolDeployed(address(tok), address(pool), address(pool.note()), pool.note().art());
        vm.prank(ADMIN);
        factory.register(address(tok), address(pool));
        assertEq(factory.poolFor(address(tok)), address(pool));
    }

    /// The F1 discovery half: a successor commit flips activePool, registration follows, and the
    /// slot the old rule froze forever now points at the successor. The incumbent is refused.
    function test_successionReplacesTheRegistryEntry() public {
        EsseyPool old = _register(address(tok));
        EsseyPool successor = _wiredPool(address(tok), mk);
        _commitAsActive(address(tok), successor);
        vm.expectEmit(true, true, false, true, address(factory));
        emit PoolFactory.PoolDeployed(
            address(tok), address(successor), address(successor.note()), successor.note().art()
        );
        vm.prank(ADMIN);
        factory.register(address(tok), address(successor));
        assertEq(factory.poolFor(address(tok)), address(successor), "registry follows the authority");

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(PoolFactory.NotActivePool.selector, address(tok), address(successor), address(old))
        );
        factory.register(address(tok), address(old));
    }

    function test_distinctTokensEachGetTheirOwnPool() public {
        EsseyPool a = _register(address(tok));
        MockStock other = new MockStock();
        px = new MockFeed(200e8, 8); // fresh feed: _commitAsActive stamps whatever px holds
        EsseyPool b = _register(address(other));
        assertTrue(address(a) != address(b));
        assertEq(factory.poolFor(address(tok)), address(a));
        assertEq(factory.poolFor(address(other)), address(b));
    }

    function test_registerOnlyAdmin() public {
        EsseyPool pool = _wiredPool(address(tok), mk);
        _commitAsActive(address(tok), pool);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PoolFactory.NotAdmin.selector);
        factory.register(address(tok), address(pool));
    }

    /// The zero clause's own pin: activePool(never-committed) == 0, so register(token, 0) would
    /// sail past a bare equality — it must die on the named error, not a decode failure.
    function test_registerRejectsTheZeroPoolLoudly() public {
        address other = makeAddr("neverCommitted");
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(PoolFactory.NotActivePool.selector, other, address(0), address(0))
        );
        factory.register(other, address(0));
    }

    /// A token with no committed market has no activePool: nothing can occupy its slot.
    function test_registerRejectsATokenWithNoActivePool() public {
        EsseyPool pool = _wiredPool(address(tok), mk);
        address other = makeAddr("otherToken");
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(PoolFactory.NotActivePool.selector, other, address(0), address(pool))
        );
        factory.register(other, address(pool));
    }

    /// The squat protection, now via the authority chain: a pool built against someone else's
    /// EsseyMarkets can never BE this registry's activePool (commit refuses the binding), so the
    /// factory refuses it as not-active.
    function test_registerRejectsAPoolOnForeignMarkets() public {
        EsseyMarkets foreign = _newMarkets(ADMIN);
        EsseyPool pool = _wiredPool(address(tok), foreign);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(PoolFactory.NotActivePool.selector, address(tok), address(0), address(pool))
        );
        factory.register(address(tok), address(pool));
    }

    /// Art is NOT checked at commit, so these two stay load-bearing at register time.
    function test_registerRejectsAPoolWithUnwiredArt() public {
        EsseyPool pool =
            new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), TREASURY, 0, _identity("AAPL"));
        _commitAsActive(address(tok), pool);
        vm.prank(ADMIN);
        vm.expectRevert(PoolFactory.ArtNotWired.selector);
        factory.register(address(tok), address(pool));
    }

    /// A-2: an art bound to a DIFFERENT pool renders the wrong pool's positions on bearer Notes.
    function test_registerRejectsArtBoundToAnotherPool() public {
        EsseyPool strayPool =
            new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), TREASURY, 0, _identity("AAPL"));
        EsseyPool pool =
            new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), TREASURY, 0, _identity("AAPL"));
        _commitAsActive(address(tok), pool);
        NoteArt strayArt = new NoteArt(strayPool, strayPool.note());
        vm.mockCall(
            address(pool.note()), abi.encodeWithSignature("art()"), abi.encode(address(strayArt))
        );
        vm.prank(ADMIN);
        vm.expectRevert(PoolFactory.ArtMismatch.selector);
        factory.register(address(tok), address(pool));
    }

    /// "No post-registration authority" is structural: the factory is neither the pool's admin nor
    /// its deployer, so even its one former write path is closed to it.
    function test_factoryHasNoAuthorityOverARegisteredPool() public {
        EsseyPool pool = _register(address(tok));
        NoteArt art2 = new NoteArt(pool, pool.note());
        vm.prank(address(factory));
        vm.expectRevert(EsseyPool.NotAdmin.selector);
        pool.setNoteArt(address(art2));
    }
}
