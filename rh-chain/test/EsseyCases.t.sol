// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {EsseyCases} from "../src/market/EsseyCases.sol";
import {StaleFeedGuard} from "../src/StaleFeedGuard.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "./RiskModules.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// A 6-decimal stock token — exercises the /10^tokenDecimals normalization with td != 18.
contract SixDecMock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract EsseyCasesTest is Test {
    Seat seat;
    ERC20Mock essey;
    ERC20Mock usdg; // base == Bell reward
    ERC20Mock aapl;
    ERC20Mock nvda;
    Bell bell;
    EsseyCases cases_;
    MockFeed baseFeed;
    MockFeed aaplFeed;
    MockFeed nvdaFeed;

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xCA5E); // convenience settler: may open a Case, prize goes to the buyer

    uint256 constant CASE_PRICE = 100e18; // $ESSEY
    uint256 constant BUY_FEE = 5e18; // USDG
    uint256 constant SPREAD_BPS = 500; // 5% sell-back discount
    uint256 constant BOOSTER_BPS = 7000;
    uint256 constant UNIT_AAPL = 1e18; // 1 share per unit
    uint256 constant UNIT_NVDA = 2e18;

    // Wednesday 2025-01-08, 15:00 UTC — inside the conservative US session window.
    uint256 constant IN_SESSION_TS = 1_736_348_400;

    function setUp() public {
        vm.warp(IN_SESSION_TS); // feeds constructed after this stamp updatedAt in-session
        vm.roll(1000);

        seat = new Seat("Essey Seat", "SEAT", 2222, address(this));
        essey = new ERC20Mock();
        usdg = new ERC20Mock();
        aapl = new ERC20Mock();
        nvda = new ERC20Mock();

        uint256[] memory fees = new uint256[](1);
        fees[0] = 100e18;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;
        bell = new Bell(ISeatLike(address(seat)), essey, usdg, treasury, 1e18, 100, fees, weights, IConverter(address(0)), address(0));

        baseFeed = new MockFeed(1e8, 8); // USDG = $1
        aaplFeed = new MockFeed(200e8, 8); // AAPL = $200
        nvdaFeed = new MockFeed(120e8, 8); // NVDA = $120

        cases_ = new EsseyCases(
            essey, bell, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)),
            treasury, address(this), CASE_PRICE, BUY_FEE, SPREAD_BPS, BOOSTER_BPS, keeper
        );

        cases_.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)), UNIT_AAPL);
        cases_.listStock(address(nvda), AggregatorV3Interface(address(nvdaFeed)), UNIT_NVDA);

        // Seed the bankroll: 3 AAPL units + 2 NVDA units.
        aapl.mint(address(this), 10e18);
        nvda.mint(address(this), 10e18);
        aapl.approve(address(cases_), type(uint256).max);
        nvda.approve(address(cases_), type(uint256).max);
        cases_.seedUnits(address(aapl), 3);
        cases_.seedUnits(address(nvda), 2);

        // Fund the buyback reserve.
        usdg.mint(address(this), 10_000e18);
        usdg.approve(address(cases_), type(uint256).max);
        cases_.fundBuyback(1_000e18);

        // alice: $ESSEY for prices, USDG for fees.
        essey.mint(alice, 10_000e18);
        usdg.mint(alice, 1_000e18);
        vm.startPrank(alice);
        essey.approve(address(cases_), type(uint256).max);
        usdg.approve(address(cases_), type(uint256).max);
        vm.stopPrank();
    }

    function _buyAndOpen(address who) internal returns (uint256 id, address token, uint256 amount) {
        vm.prank(who);
        id = cases_.buy();
        vm.roll(block.number + 2);
        vm.prank(who);
        (token, amount) = cases_.open(id);
    }

    // ------------------------------------------------- bankroll + backing invariant

    function test_SeedBuildsInventory() public view {
        assertEq(cases_.inventoryCount(), 5);
        assertEq(cases_.freeInventory(), 5);
        assertEq(aapl.balanceOf(address(cases_)), 3e18, "3 AAPL units held");
        assertEq(nvda.balanceOf(address(cases_)), 4e18, "2 NVDA units of 2e18 held");
    }

    function test_BuyRequiresBackingInventory() public {
        // Drain the backing: buy 5 (all backed), the 6th has no reserved prize.
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            cases_.buy();
        }
        vm.expectRevert(EsseyCases.NoBackingInventory.selector);
        cases_.buy();
        vm.stopPrank();
        assertEq(cases_.freeInventory(), 0, "every unopened Case is backed");
    }

    function test_SellBackRestoresBacking() public {
        // 5 unopened = fully committed; a sell-back adds a unit, freeing one more Case.
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            cases_.buy();
        }
        vm.stopPrank();
        aapl.mint(bob, 1e18);
        usdg.mint(address(cases_), 0); // no-op, clarity
        vm.startPrank(bob);
        aapl.approve(address(cases_), 1e18);
        cases_.sellBack(address(aapl));
        vm.stopPrank();
        vm.prank(alice);
        cases_.buy(); // now backed again
        assertEq(cases_.unopened(), 6);
    }

    // ------------------------------------------------- buy

    function test_BuyRoutesPriceAndFee() public {
        uint256 potBefore = bell.pot();
        vm.prank(alice);
        cases_.buy();

        assertEq(essey.balanceOf(treasury), CASE_PRICE, "case price sunk to treasury");
        assertEq(bell.pot() - potBefore, (BUY_FEE * BOOSTER_BPS) / 10_000, "booster share grew the pot");
        assertEq(usdg.balanceOf(treasury), BUY_FEE - (BUY_FEE * BOOSTER_BPS) / 10_000, "rest to treasury");
        assertEq(cases_.unopened(), 1);
    }

    // ------------------------------------------------- open (the draw)

    function test_OpenDeliversAUnit() public {
        (, address token, uint256 amount) = _buyAndOpen(alice);
        assertTrue(token == address(aapl) || token == address(nvda), "drew a listed stock");
        assertEq(amount, token == address(aapl) ? UNIT_AAPL : UNIT_NVDA, "full unit delivered");
        assertEq(ERC20Mock(token).balanceOf(alice), amount, "prize in the buyer's wallet");
        assertEq(cases_.inventoryCount(), 4);
        assertEq(cases_.unopened(), 0);
    }

    function test_OpenSameBlockReverts() public {
        vm.startPrank(alice);
        uint256 id = cases_.buy();
        vm.expectRevert(EsseyCases.DrawNotReady.selector);
        cases_.open(id);
        vm.stopPrank();
    }

    function test_OnlyBuyerOpens() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 2);
        vm.prank(bob); // neither the buyer nor the keeper
        vm.expectRevert(EsseyCases.NotYourCase.selector);
        cases_.open(id);
    }

    function test_KeeperOpensDeliversToBuyer() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 2);
        // The keeper opens on the buyer's behalf; the prize lands in the BUYER's wallet, not the keeper's.
        vm.prank(keeper);
        (address token, uint256 amount) = cases_.open(id);
        assertEq(ERC20Mock(token).balanceOf(alice), amount, "prize delivered to the buyer");
        assertEq(ERC20Mock(token).balanceOf(keeper), 0, "keeper receives nothing");
        assertEq(cases_.unopened(), 0, "backing released");
    }

    function test_DoubleOpenReverts() public {
        (uint256 id,,) = _buyAndOpen(alice);
        vm.prank(alice);
        vm.expectRevert(EsseyCases.AlreadyOpened.selector);
        cases_.open(id);
    }

    /// An expired draw is NEVER a re-roll: it pays the current lowest-oracle-value unit, so
    /// draw-shopping (letting draws you dislike lapse) is strictly dominated by opening in time.
    function test_ExpiredCaseClaimsFloorUnit() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 300); // past the 256-block blockhash window

        vm.prank(alice);
        vm.expectRevert(EsseyCases.DrawExpired.selector);
        cases_.open(id);

        vm.prank(bob);
        vm.expectRevert(EsseyCases.NotYourCase.selector);
        cases_.claimExpired(id);

        // Floor unit: AAPL 1 x $200 = $200 < NVDA 2 x $120 = $240.
        vm.prank(alice);
        (address token, uint256 amount) = cases_.claimExpired(id);
        assertEq(token, address(aapl), "lowest-value unit delivered, not a fresh roll");
        assertEq(amount, UNIT_AAPL);
        assertEq(cases_.unopened(), 0);
        assertEq(cases_.inventoryCount(), 4);
    }

    function test_ExpiredClaimTracksLiveFloor() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 300);
        // AAPL rallies past NVDA's unit value: floor flips to NVDA (2 x $120 = $240 < 1 x $300).
        aaplFeed.set(300e8, block.timestamp);
        vm.prank(alice);
        (address token,) = cases_.claimExpired(id);
        assertEq(token, address(nvda), "floor recomputed at claim time");
    }

    function test_ExpiredClaimOffSessionReverts() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 300);
        vm.warp(IN_SESSION_TS + 3 days); // Saturday — no verifiable floor price
        baseFeed.set(1e8, block.timestamp);
        aaplFeed.set(200e8, block.timestamp);
        nvdaFeed.set(120e8, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(EsseyCases.NotInSession.selector);
        cases_.claimExpired(id);
    }

    function test_ClaimExpiredBeforeExpiryReverts() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 2); // draw is live, not expired
        vm.prank(alice);
        vm.expectRevert(EsseyCases.DrawNotExpired.selector);
        cases_.claimExpired(id);
    }

    function test_ClaimExpiredTwiceReverts() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 300);
        vm.startPrank(alice);
        cases_.claimExpired(id);
        vm.expectRevert(EsseyCases.AlreadyOpened.selector);
        cases_.claimExpired(id);
        // The settled case can't be re-opened through the live path either.
        vm.expectRevert(EsseyCases.AlreadyOpened.selector);
        cases_.open(id);
        vm.stopPrank();
    }

    /// The expired-claim window is bounded: without a TTL it is an unbounded American option on
    /// min(inventory value) — wait for cheap units to drain, then claim a floor that beats the
    /// abandoned draw.
    function test_ClaimLapsesAfterTtl() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 300);
        // Monday 15:00 UTC, 12 days after purchase — in-session with fresh feeds, so ONLY the TTL
        // gate can fire.
        vm.warp(IN_SESSION_TS + 12 days);
        baseFeed.set(1e8, block.timestamp);
        aaplFeed.set(200e8, block.timestamp);
        nvdaFeed.set(120e8, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(EsseyCases.ClaimLapsed.selector);
        cases_.claimExpired(id);
    }

    function test_SweepAbandonedFreesBacking() public {
        // Fill the backing entirely, abandon one case past the TTL, sweep it, and buy again.
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            cases_.buy();
        }
        vm.expectRevert(EsseyCases.NoBackingInventory.selector);
        cases_.buy();
        vm.stopPrank();

        vm.roll(block.number + 300); // draw window lapsed...
        vm.warp(block.timestamp + 7 days + 1); // ...AND the claim TTL — both clocks required
        vm.prank(bob); // anyone may sweep — the buyer forfeited
        cases_.sweepAbandoned(0);
        assertEq(cases_.unopened(), 4, "backing freed");
        assertEq(cases_.inventoryCount(), 5, "prize unit stayed in the pool");
        vm.prank(alice);
        cases_.buy(); // backed again

        // Swept case is settled: no open, no claim, no double-sweep.
        vm.startPrank(alice);
        vm.expectRevert(EsseyCases.AlreadyOpened.selector);
        cases_.open(0);
        vm.expectRevert(EsseyCases.AlreadyOpened.selector);
        cases_.claimExpired(0);
        vm.stopPrank();
        vm.expectRevert(EsseyCases.AlreadyOpened.selector);
        cases_.sweepAbandoned(0);
    }

    function test_SweepBeforeTtlReverts() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 300); // draw expired, but TTL not lapsed
        vm.expectRevert(EsseyCases.DrawNotExpired.selector);
        cases_.sweepAbandoned(id);
        vm.expectRevert(EsseyCases.NotYourCase.selector);
        cases_.sweepAbandoned(999); // nonexistent
    }

    /// A chain halt decouples the wall-clock TTL from the block-count draw window: a still-openable
    /// case must never be sweepable out from under its buyer (audit round-3 L-1).
    function test_SweepRequiresDrawExpiryNotJustTtl() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        // 8 days pass but almost no blocks: the draw is still live (blockhash exists).
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(EsseyCases.DrawNotExpired.selector);
        cases_.sweepAbandoned(id);
        // The buyer can still open their live draw.
        vm.prank(alice);
        cases_.open(id);
    }

    /// The TTL seam is exact: claim succeeds AT the boundary second, sweep only strictly after.
    function test_TtlBoundarySeamIsExact() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        uint256 boughtAt = block.timestamp;
        vm.roll(block.number + 300);
        vm.warp(boughtAt + 7 days); // exactly the boundary — claim ok, sweep not
        // Re-land in session for the floor scan: boundary math is what we assert, so pick feeds fresh.
        baseFeed.set(1e8, block.timestamp);
        aaplFeed.set(200e8, block.timestamp);
        nvdaFeed.set(120e8, block.timestamp);
        vm.expectRevert(EsseyCases.DrawNotExpired.selector);
        cases_.sweepAbandoned(id);
        // (claim at the boundary requires an in-session weekday; 7 days after Wed 15:00 UTC is
        // Wed 15:00 UTC — in session, so the claim path is genuinely exercised.)
        vm.prank(alice);
        cases_.claimExpired(id);
    }

    /// A single dead feed must not brick every expired claim: its token is skipped as a floor
    /// candidate rather than reverting the scan.
    function test_DeadFeedSkippedInFloorScan() public {
        vm.prank(alice);
        uint256 id = cases_.buy();
        vm.roll(block.number + 300);
        // AAPL's feed goes silent past the broken-oracle bound; NVDA and base stay fresh.
        aaplFeed.set(200e8, block.timestamp - 100_000);
        vm.prank(alice);
        (address token,) = cases_.claimExpired(id);
        assertEq(token, address(nvda), "dead-feed token excluded; live floor delivered");
    }

    // ------------------------------------------------- sell-back

    function test_SellBackPaysOracleValueMinusSpread() public {
        aapl.mint(bob, 1e18);
        uint256 potBefore = bell.pot();
        vm.startPrank(bob);
        aapl.approve(address(cases_), 1e18);
        uint256 paid = cases_.sellBack(address(aapl));
        vm.stopPrank();

        // 1 AAPL @ $200, base $1 (18 dec): gross 200e18; 5% spread -> 190e18 paid, 10e18 spread.
        assertEq(paid, 190e18, "oracle value minus the spread");
        assertEq(usdg.balanceOf(bob), 190e18);
        assertEq(bell.pot() - potBefore, 7e18, "70% of the spread feeds the Bell");
        assertEq(cases_.inventoryCount(), 6, "unit re-entered the prize pool");
    }

    /// Non-1:1 unit sizing: NVDA's unit is 2 shares, so the /10^tokenDecimals normalization is NOT a
    /// silent no-op here (audit round-1 test-gap note).
    function test_SellBackNonUnitAmountNormalization() public {
        nvda.mint(bob, 2e18);
        uint256 potBefore = bell.pot();
        vm.startPrank(bob);
        nvda.approve(address(cases_), 2e18);
        uint256 paid = cases_.sellBack(address(nvda));
        vm.stopPrank();

        // 2 NVDA @ $120 = $240 gross; 5% spread -> 228 paid, 12 spread, 70% of 12 = 8.4 to the Bell.
        assertEq(paid, 228e18, "two-share unit priced correctly");
        assertEq(bell.pot() - potBefore, 8.4e18);
    }

    /// Heterogeneous decimals: a 6-decimal stock at a fractional unit size, priced against the
    /// 18-decimal base — the full normalization path with td != 18 (audit round-2 test-gap note).
    function test_SellBackSixDecimalStock() public {
        SixDecMock spy = new SixDecMock();
        MockFeed spyFeed = new MockFeed(400e8, 8); // $400
        cases_.listStock(address(spy), AggregatorV3Interface(address(spyFeed)), 5e5); // 0.5 share/unit

        spy.mint(bob, 5e5);
        vm.startPrank(bob);
        spy.approve(address(cases_), 5e5);
        uint256 paid = cases_.sellBack(address(spy));
        vm.stopPrank();

        // 0.5 x $400 = $200 gross in 18-dec base; 5% spread -> 190.
        assertEq(paid, 190e18, "6-dec unit normalized correctly");
        assertEq(cases_.inventoryCount(), 6, "unit joined the pool");
    }

    function test_SellBackOffSessionReverts() public {
        // Saturday: no verifiable equity price, no buyback. Feeds are refreshed post-warp so the
        // SESSION gate (not the staleness gate) is what fires — staleness is covered separately.
        vm.warp(IN_SESSION_TS + 3 days); // Wed + 3 = Saturday
        baseFeed.set(1e8, block.timestamp);
        aaplFeed.set(200e8, block.timestamp);
        aapl.mint(bob, 1e18);
        vm.startPrank(bob);
        aapl.approve(address(cases_), 1e18);
        vm.expectRevert(EsseyCases.NotInSession.selector);
        cases_.sellBack(address(aapl));
        vm.stopPrank();
    }

    function test_SellBackStaleFeedReverts() public {
        aaplFeed.set(200e8, block.timestamp - 100_000); // silent past heartbeat + grace
        aapl.mint(bob, 1e18);
        vm.startPrank(bob);
        aapl.approve(address(cases_), 1e18);
        vm.expectRevert(); // PriceStale from StaleFeedGuard
        cases_.sellBack(address(aapl));
        vm.stopPrank();
    }

    function test_SellBackUnlistedReverts() public {
        ERC20Mock other = new ERC20Mock();
        vm.expectRevert(EsseyCases.NotListed.selector);
        cases_.sellBack(address(other));
    }

    function test_SellBackWithEmptyReserveReverts() public {
        // A reserve smaller than the payout: drain by selling repeatedly.
        aapl.mint(bob, 6e18);
        vm.startPrank(bob);
        aapl.approve(address(cases_), type(uint256).max);
        for (uint256 i = 0; i < 5; i++) {
            cases_.sellBack(address(aapl)); // 5 × 190 = 950 paid + 5 × 7 to the Bell = 985 of 1000
        }
        vm.expectRevert(); // ERC20 insufficient balance — a liquidity constraint, not a loss
        cases_.sellBack(address(aapl));
        vm.stopPrank();
    }

    // ------------------------------------------------- roles + config

    function test_OnlyBankrollListsAndSeeds() public {
        vm.startPrank(bob);
        vm.expectRevert(EsseyCases.NotBankroll.selector);
        cases_.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)), 1e18);
        vm.expectRevert(EsseyCases.NotBankroll.selector);
        cases_.seedUnits(address(aapl), 1);
        vm.stopPrank();
    }

    function test_ListStockIsAppendOnly() public {
        vm.expectRevert(EsseyCases.AlreadyListed.selector);
        cases_.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)), 5e18);
    }

    function test_ConfigGuards() public {
        // essey == reward token rejected.
        Bell esseyRewardBell;
        {
            uint256[] memory f = new uint256[](1);
            f[0] = 1e18;
            uint256[] memory w = new uint256[](1);
            w[0] = 1;
            esseyRewardBell = new Bell(ISeatLike(address(seat)), usdg, essey, treasury, 1e18, 100, f, w, IConverter(address(0)), address(0));
        }
        vm.expectRevert(EsseyCases.BadConfig.selector);
        new EsseyCases(
            essey, esseyRewardBell, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)),
            treasury, address(this), CASE_PRICE, BUY_FEE, SPREAD_BPS, BOOSTER_BPS, keeper
        );
        // Spread below the floor (must clear BOTH legs' 0.5% oracle deviation bands) and > 20% both
        // rejected.
        vm.expectRevert(EsseyCases.BadConfig.selector);
        new EsseyCases(
            essey, bell, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)),
            treasury, address(this), CASE_PRICE, BUY_FEE, 149, BOOSTER_BPS, keeper
        );
        vm.expectRevert(EsseyCases.BadConfig.selector);
        new EsseyCases(
            essey, bell, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)),
            treasury, address(this), CASE_PRICE, BUY_FEE, 2001, BOOSTER_BPS, keeper
        );
    }

    // ------------------------------------------------- end-to-end: Case fees pay out at the Bell

    function test_CaseFeesDistributeThroughBell() public {
        vm.prank(alice);
        uint256 id = cases_.buy(); // 3.5 USDG into the pot
        vm.roll(block.number + 2);
        vm.prank(alice);
        cases_.open(id);

        // alice activates a Seat and claims the pot her Case funded.
        uint256 seatId = seat.mint(alice);
        essey.mint(alice, 1_000e18);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(seatId, 1);
        vm.stopPrank();

        bell.ring(); // pot 3.5, tip 1% = 0.035 -> 3.465 to the sole active Seat
        bell.claim(seatId);
        assertEq(usdg.balanceOf(seat.vaultOf(seatId)), 3.465e18, "Case-sourced fee reached the Vault");
    }
}
