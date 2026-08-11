// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {BundleConverter} from "../src/market/BundleConverter.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "./RiskModules.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// A 6-decimal base, matching production USDG on Robinhood Chain (testnet's mock is 18-dec).
contract ERC20Mock6 is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// BundleConverter — the inventory claim-edge that pays Seats in real stock (a default basket, or an
/// opt-in single stock), delivered straight to the Vault and failing open to USDG when the market
/// can't settle. Mirrors StockConverter.t.sol's Bell+converter+feeds+session scaffolding.
contract BundleConverterTest is Test {
    // Monday 15:00 UTC — inside the conservative US session window.
    uint256 constant MON_IN_SESSION = 1_753_110_000;

    Seat seat;
    Bell bell;
    BundleConverter conv;
    ERC20Mock usdg; // base reward asset ($1)
    ERC20Mock aapl; // $200/share
    ERC20Mock nvda; // $125/share
    ERC20Mock essey;
    MockFeed baseFeed;
    MockFeed aaplFeed;
    MockFeed nvdaFeed;

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256[] fees = [100e18, 250e18, 500e18, 1500e18];
    uint256[] weights = [100, 160, 200, 333];

    function setUp() public {
        vm.warp(MON_IN_SESSION);

        usdg = new ERC20Mock();
        aapl = new ERC20Mock();
        nvda = new ERC20Mock();
        essey = new ERC20Mock();
        baseFeed = new MockFeed(1e8, 8); // $1
        aaplFeed = new MockFeed(200e8, 8); // $200
        nvdaFeed = new MockFeed(125e8, 8); // $125

        // spreadBps 0 = full oracle value in stock; this test contract is the bankroll.
        conv = new BundleConverter(
            usdg, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)), address(this), treasury, 0
        );
        conv.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)));
        conv.listStock(address(nvda), AggregatorV3Interface(address(nvdaFeed)));
        conv.addBundleMember(address(aapl));
        conv.addBundleMember(address(nvda));

        // Seed the payout reserve generously.
        aapl.mint(address(this), 1_000_000e18);
        nvda.mint(address(this), 1_000_000e18);
        aapl.approve(address(conv), type(uint256).max);
        nvda.approve(address(conv), type(uint256).max);
        conv.seedReserve(address(aapl), 100_000e18);
        conv.seedReserve(address(nvda), 100_000e18);

        seat = new Seat("Essey Seat", "SEAT", 4444, address(this));
        // defaultPayout = BUNDLE: an unset Seat is paid the basket.
        bell = new Bell(ISeatLike(address(seat)), essey, usdg, treasury, 100e18, 100, fees, weights, conv, conv.BUNDLE());
        seat.setHook(address(bell));
        conv.initBell(address(bell)); // gate convert() to this Bell — the only legitimate caller

        essey.mint(alice, 10_000e18);
        vm.prank(alice);
        essey.approve(address(bell), type(uint256).max);
    }

    /// A converter gated to THIS test contract, so tests can call convert() directly (bundle: AAPL+NVDA).
    function _gatedConv(uint256 spread) internal returns (BundleConverter g) {
        g = new BundleConverter(
            usdg, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)), address(this), treasury, spread
        );
        g.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)));
        g.listStock(address(nvda), AggregatorV3Interface(address(nvdaFeed)));
        g.addBundleMember(address(aapl));
        g.addBundleMember(address(nvda));
        aapl.approve(address(g), type(uint256).max);
        nvda.approve(address(g), type(uint256).max);
        g.seedReserve(address(aapl), 100_000e18);
        g.seedReserve(address(nvda), 100_000e18);
        g.initBell(address(this));
    }

    /// One activated seat, 1000 funded, ring: tip 10, distributed 990.
    function _oneSeatRung() internal returns (uint256 id) {
        id = seat.mint(alice);
        vm.prank(alice);
        bell.activate(id, 1);
        usdg.mint(address(bell), 1000e18);
        bell.ring();
    }

    /// THE HEADLINE: a Seat with NO explicit choice is paid the bundle automatically — 990 USDG split
    /// 495/495 → 2.475 AAPL ($200) + 3.96 NVDA ($125), oracle-fair, straight to the Vault.
    function test_DefaultPaysBundle() public {
        uint256 id = _oneSeatRung();
        assertEq(bell.payoutTokenOf(id), address(0), "no explicit preference");

        bell.claim(id); // permissionless; routes to defaultPayout = BUNDLE
        address vault = seat.vaultOf(id);
        assertEq(aapl.balanceOf(vault), 2.475e18, "AAPL leg: 495 USDG @ $200");
        assertEq(nvda.balanceOf(vault), 3.96e18, "NVDA leg: 495 USDG @ $125");
        assertEq(usdg.balanceOf(vault), 0, "no base when the bundle settles");
        assertEq(bell.reserved(), 0, "accounting settled");
        assertEq(usdg.balanceOf(address(conv)), 0, "converter holds no base at rest");
        assertEq(usdg.balanceOf(treasury), 990e18, "base proceeds forwarded to treasury");
        assertEq(usdg.allowance(address(bell), address(conv)), 0, "no standing allowance after a successful convert");
    }

    /// Opt-in: a Seat that picks a single stock is paid only that stock. 990 at $200 → 4.95 AAPL.
    function test_ElectSingleStock() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(aapl));

        bell.claim(id);
        address vault = seat.vaultOf(id);
        assertEq(aapl.balanceOf(vault), 4.95e18, "full payout in the chosen stock");
        assertEq(nvda.balanceOf(vault), 0, "no other stock");
        assertEq(usdg.balanceOf(vault), 0);
    }

    /// Opt-in to the bundle explicitly is identical to the default.
    function test_ElectBundleExplicitly() public {
        uint256 id = _oneSeatRung();
        address bundle = conv.BUNDLE(); // hoist: vm.prank applies to the next CALL, don't spend it on BUNDLE()
        vm.prank(alice);
        bell.setPayoutToken(id, bundle);

        bell.claim(id);
        address vault = seat.vaultOf(id);
        assertEq(aapl.balanceOf(vault), 2.475e18);
        assertEq(nvda.balanceOf(vault), 3.96e18);
    }

    /// Fails open off-session: no verifiable equity price → the whole bundle declines → base delivered.
    function test_FallbackOffSession() public {
        uint256 id = _oneSeatRung();
        vm.warp(MON_IN_SESSION + 8 hours); // 23:00 UTC — closed, feeds still fresh

        bell.claim(id);
        address vault = seat.vaultOf(id);
        assertEq(usdg.balanceOf(vault), 990e18, "base delivered off-hours");
        assertEq(aapl.balanceOf(vault), 0);
        assertEq(nvda.balanceOf(vault), 0);
    }

    /// Fails open on a silent feed (staleness bound exceeded) → base delivered.
    function test_FallbackStaleFeed() public {
        uint256 id = _oneSeatRung();
        vm.warp(MON_IN_SESSION + 2 days); // Wednesday in-session, but 48h with no feed update > 25h bound

        bell.claim(id);
        assertEq(usdg.balanceOf(seat.vaultOf(id)), 990e18, "base delivered on silent oracle");
    }

    /// Fails open when the reserve can't cover a leg — the transfer reverts, the Bell pays base. Here
    /// NVDA is drained by a first claim, so a second Seat's bundle can't settle its NVDA leg.
    function test_FallbackOnEmptyReserve() public {
        // Fresh converter with a thin NVDA reserve so one bundle exhausts it.
        BundleConverter thin = new BundleConverter(
            usdg, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)), address(this), treasury, 0
        );
        thin.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)));
        thin.listStock(address(nvda), AggregatorV3Interface(address(nvdaFeed)));
        thin.addBundleMember(address(aapl));
        thin.addBundleMember(address(nvda));
        aapl.approve(address(thin), type(uint256).max);
        nvda.approve(address(thin), type(uint256).max);
        thin.seedReserve(address(aapl), 100_000e18);
        thin.seedReserve(address(nvda), 1e18); // only 1 NVDA share — a bundle needs 3.96

        Seat s = new Seat("S", "S", 10, address(this));
        Bell b = new Bell(ISeatLike(address(s)), essey, usdg, treasury, 100e18, 100, fees, weights, thin, thin.BUNDLE());
        s.setHook(address(b));
        thin.initBell(address(b));
        uint256 id = s.mint(alice);
        vm.startPrank(alice);
        essey.approve(address(b), type(uint256).max);
        b.activate(id, 1);
        vm.stopPrank();
        usdg.mint(address(b), 1000e18);
        b.ring();

        b.claim(id);
        assertEq(usdg.balanceOf(s.vaultOf(id)), 990e18, "base delivered when a bundle leg can't cover");
        assertEq(aapl.balanceOf(s.vaultOf(id)), 0, "atomic: the AAPL leg rolled back too");
    }

    /// spreadBps applies a protective haircut off oracle-fair output (0 elsewhere in this suite).
    function test_SpreadHaircut() public {
        BundleConverter haircut = new BundleConverter(
            usdg, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)), address(this), treasury, 200
        ); // 2%
        haircut.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)));
        aapl.approve(address(haircut), type(uint256).max);
        haircut.seedReserve(address(aapl), 100_000e18);
        haircut.initBell(address(this)); // this test acts as the Bell for a direct convert

        usdg.mint(address(this), 990e18);
        usdg.approve(address(haircut), type(uint256).max);
        // 990 @ $200 fair = 4.95; minus 2% = 4.851.
        uint256 out = haircut.convert(990e18, address(aapl), bob);
        assertEq(out, 4.851e18, "2% haircut off oracle-fair 4.95");
        assertEq(aapl.balanceOf(bob), 4.851e18, "haircut stock delivered");
        assertEq(usdg.balanceOf(treasury), 990e18, "base forwarded to treasury");
    }

    /// isSupported: bundle when non-empty, listed stocks, never the base.
    function test_IsSupported() public view {
        assertTrue(conv.isSupported(conv.BUNDLE()), "bundle supported when populated");
        assertTrue(conv.isSupported(address(aapl)));
        assertTrue(conv.isSupported(address(nvda)));
        assertFalse(conv.isSupported(address(usdg)), "base is never a target");
        assertFalse(conv.isSupported(address(0xDECAF)), "unlisted");
    }

    /// Registry + reserve are bankroll-gated and append-only.
    function test_BankrollGatedAppendOnly() public {
        ERC20Mock other = new ERC20Mock();
        vm.prank(bob);
        vm.expectRevert(BundleConverter.NotBankroll.selector);
        conv.listStock(address(other), AggregatorV3Interface(address(aaplFeed)));

        vm.expectRevert(BundleConverter.AlreadyListed.selector);
        conv.listStock(address(aapl), AggregatorV3Interface(address(nvdaFeed)));

        vm.prank(bob);
        vm.expectRevert(BundleConverter.NotBankroll.selector);
        conv.seedReserve(address(aapl), 1e18);

        vm.expectRevert(BundleConverter.AlreadyInBundle.selector);
        conv.addBundleMember(address(aapl));
    }

    /// Direct convert guards: zero amount, unlisted target, and a payout too small to split.
    function test_ConvertGuards() public {
        BundleConverter g = _gatedConv(0);
        usdg.mint(address(this), 10e18);
        usdg.approve(address(g), type(uint256).max);
        address bundle = g.BUNDLE(); // hoist: expectRevert must arm the convert call, not BUNDLE()

        vm.expectRevert(BundleConverter.ZeroAmount.selector);
        g.convert(0, bundle, alice);

        vm.expectRevert(BundleConverter.NotListed.selector);
        g.convert(1e18, address(0xDECAF), alice);

        vm.expectRevert(BundleConverter.DustAmount.selector);
        g.convert(1, bundle, alice); // 1 wei / 2 members = 0 per leg
    }

    /// THE AUDIT FIX: only the wired Bell may call convert — an external caller can't touch the reserve,
    /// and the Bell wiring is one-shot.
    function test_ConvertOnlyBell() public {
        usdg.mint(bob, 990e18);
        vm.startPrank(bob);
        usdg.approve(address(conv), type(uint256).max);
        vm.expectRevert(BundleConverter.NotBell.selector);
        conv.convert(990e18, address(aapl), bob); // bob is not the Bell
        vm.stopPrank();
        assertEq(conv.reserveOf(address(aapl)), 100_000e18, "reserve untouched by a non-Bell caller");

        vm.expectRevert(BundleConverter.BellAlreadySet.selector);
        conv.initBell(address(seat)); // one-shot — already wired to the Bell in setUp
    }

    /// Production USDG is 6-decimal — verify _fairOut normalizes a non-18-dec base correctly.
    function test_SixDecimalBase() public {
        ERC20Mock6 usdg6 = new ERC20Mock6();
        BundleConverter c6 = new BundleConverter(
            usdg6, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)), address(this), treasury, 0
        );
        c6.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)));
        aapl.approve(address(c6), type(uint256).max);
        c6.seedReserve(address(aapl), 100_000e18);
        c6.initBell(address(this));

        usdg6.mint(address(this), 990e6);
        usdg6.approve(address(c6), type(uint256).max);
        uint256 out = c6.convert(990e6, address(aapl), bob);
        assertEq(out, 4.95e18, "990 (6-dec) USDG at $200 -> 4.95 AAPL (18-dec)");
        assertEq(aapl.balanceOf(bob), 4.95e18);
    }

    /// An indivisible (odd-wei) payout exercises the last-member remainder sweep: every wei converts,
    /// no base stranded. amountIn = 991e18 + 1 → part = 495.5e18, last member sweeps the extra wei.
    function test_BundleRemainderNoDust() public {
        BundleConverter g = _gatedConv(0);
        uint256 amountIn = 991e18 + 1;
        usdg.mint(address(this), amountIn);
        usdg.approve(address(g), type(uint256).max);
        uint256 tBefore = usdg.balanceOf(treasury);

        g.convert(amountIn, g.BUNDLE(), bob);
        assertEq(usdg.balanceOf(treasury) - tBefore, amountIn, "entire payout forwarded, no stranded base");
        assertEq(aapl.balanceOf(bob), 2477500000000000000, "AAPL leg: part 495.5 USDG @ $200");
        assertEq(nvda.balanceOf(bob), 3964000000000000000, "NVDA leg: 495.5 + 1 wei sweep @ $125");
    }

    /// The constructor guard (audit round 1): a defaultPayout the converter doesn't support — or a
    /// non-zero defaultPayout with no converter — must revert at DEPLOY, not silently pay base forever.
    function test_RejectsUnsupportedDefaultPayout() public {
        address bundle = conv.BUNDLE(); // hoist before expectRevert
        // converter set, but 0xDECAF is neither a listed stock nor the bundle sentinel
        vm.expectRevert(Bell.BadConfig.selector);
        new Bell(ISeatLike(address(seat)), essey, usdg, treasury, 100e18, 100, fees, weights, conv, address(0xDECAF));
        // non-zero defaultPayout with no converter to route it through
        vm.expectRevert(Bell.BadConfig.selector);
        new Bell(ISeatLike(address(seat)), essey, usdg, treasury, 100e18, 100, fees, weights, IConverter(address(0)), bundle);
    }

    /// The preference is per-owner: transferring the Seat clears it → buyer gets the default bundle.
    function test_TransferClearsPreference() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(aapl));

        vm.prank(alice);
        seat.transferFrom(alice, bob, id);
        assertEq(bell.payoutTokenOf(id), address(0), "preference cleared on transfer");

        bell.claim(id); // now defaults to the bundle again
        assertEq(aapl.balanceOf(seat.vaultOf(id)), 2.475e18, "back to the default bundle");
        assertEq(nvda.balanceOf(seat.vaultOf(id)), 3.96e18);
    }
}
