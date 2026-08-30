// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {StockConverter} from "../src/market/StockConverter.sol";
import {IConverter, ISwapRouter} from "../src/market/IConverter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "./RiskModules.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Uniswap-shaped mock router: fixed rate, honors amountOutMinimum (reverts like the real router when
/// the pool can't beat it), settable hard-failure mode.
contract MockRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    uint256 public rate; // tokenOut per tokenIn, 1e18-scaled
    bool public failNext;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setFail(bool f) external {
        failNext = f;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(!failNext, "router down");
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        out = (p.amountIn * rate) / 1e18;
        require(out >= p.amountOutMinimum, "Too little received"); // Uniswap's own guard
        IERC20(p.tokenOut).safeTransfer(p.recipient, out);
    }
}

/// A rogue converter that reports success but pulls only PART of the approved base — used to prove the
/// Bell never leaves a standing allowance regardless of converter behavior.
contract UnderpullingConverter is IConverter {
    using SafeERC20 for IERC20;

    IERC20 public immutable base;

    constructor(IERC20 base_) {
        base = base_;
    }

    function isSupported(address) external pure returns (bool) {
        return true;
    }

    function convert(uint256 amountIn, address, address recipient) external returns (uint256) {
        base.safeTransferFrom(msg.sender, recipient, amountIn / 2); // pulls HALF, "succeeds"
        return amountIn / 2;
    }
}

contract StockConverterTest is Test {
    // Monday 15:00 UTC — inside the conservative US session window (same anchor as the pool tests).
    uint256 constant MON_IN_SESSION = 1_753_110_000;

    Seat seat;
    Bell bell;
    StockConverter conv;
    MockRouter router;
    ERC20Mock usdg; // base reward asset ($1)
    ERC20Mock stock; // $200/share stock token
    ERC20Mock essey;
    MockFeed baseFeed;
    MockFeed stockFeed;

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256[] fees = [100e18, 250e18, 500e18, 1500e18];
    uint256[] weights = [100, 160, 200, 333];

    function setUp() public {
        vm.warp(MON_IN_SESSION);

        usdg = new ERC20Mock();
        stock = new ERC20Mock();
        essey = new ERC20Mock();
        baseFeed = new MockFeed(1e8, 8); // $1
        stockFeed = new MockFeed(200e8, 8); // $200

        // Fair rate: 1 USDG buys 1/200 share -> 5e15.
        router = new MockRouter(5e15);
        stock.mint(address(router), 1_000_000e18);

        conv = new StockConverter(
            router, usdg, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)), 100, address(this)
        ); // 1% slippage, this test is registrar
        conv.listStock(address(stock), AggregatorV3Interface(address(stockFeed)), 3000);

        seat = new Seat("Essey Seat", "SEAT", 4444, address(this));
        bell = new Bell(ISeatLike(address(seat)), essey, usdg, treasury, 100e18, 100, fees, weights, conv, address(0));
        seat.setHook(address(bell));

        essey.mint(alice, 10_000e18);
        vm.prank(alice);
        essey.approve(address(bell), type(uint256).max);
    }

    /// One activated seat, 1000 funded, ring: tip 10, distributed 990.
    function _oneSeatRung() internal returns (uint256 id) {
        id = seat.mint(alice);
        vm.prank(alice);
        bell.activate(id, 1);
        usdg.mint(address(bell), 1000e18);
        bell.ring();
    }

    /// The headline mechanic: owner opts into stock, claim converts at oracle-fair rate, stock lands
    /// in the Vault. 990 USDG @ $200/share -> 4.95 shares.
    /// M-2: the migrated per-feed staleness window MUST stay pinned — heartbeat 86_400s, maxStaleness
    /// 90_000s. Reads the STORED config (NOT a dynamic FEED_HEARTBEAT() expression, which self-adjusts
    /// with the constant): a widening (dangerous direction, e.g. 86_400 -> 172_800 => ~49h stale
    /// window) would otherwise ship green. Also proves a price past the window is refused.
    function test_feedStalenessWindowIsPinned() public {
        assertEq(uint256(conv.feedConfig(address(stock)).maxStaleness), 90_000, "maxStaleness pinned");
        assertEq(uint256(conv.feedConfig(address(stock)).heartbeat), 86_400, "heartbeat pinned");
        vm.warp(block.timestamp + 90_001); // one second past the window
        vm.expectRevert();
        conv.priceOf(address(stock));
    }

    function test_ClaimConvertsToStock() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(stock));

        bell.claim(id); // permissionless, honors the owner's preference
        address vault = seat.vaultOf(id);
        assertEq(stock.balanceOf(vault), 4.95e18, "oracle-fair stock delivered to the vault");
        assertEq(usdg.balanceOf(vault), 0, "no base when conversion succeeds");
        assertEq(bell.reserved(), 0, "accounting settled");
        assertEq(usdg.allowance(address(bell), address(conv)), 0, "approval fully consumed");
    }

    /// Fails open: router hard-down -> the claim still pays, in base.
    function test_FallbackOnRouterFailure() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(stock));
        router.setFail(true);

        bell.claim(id);
        address vault = seat.vaultOf(id);
        assertEq(usdg.balanceOf(vault), 990e18, "base delivered instead");
        assertEq(stock.balanceOf(vault), 0);
        assertEq(usdg.allowance(address(bell), address(conv)), 0, "approval reset on fallback");
    }

    /// Fails open: pool prices worse than oracle-minus-slippage -> router's minOut guard trips ->
    /// base delivered. A keeper can never get a Seat sandwiched into dust.
    function test_FallbackOnBadPoolPrice() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(stock));
        router.setRate(4e15); // ~20% worse than fair — far outside the 1% bound

        bell.claim(id);
        assertEq(usdg.balanceOf(seat.vaultOf(id)), 990e18, "base delivered");
        assertEq(stock.balanceOf(seat.vaultOf(id)), 0);
    }

    /// The exact boundary: a pool delivering precisely oracle*(1-slippage) is accepted.
    function test_ConvertAtExactMinOut() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(stock));
        router.setRate(4.95e15); // exactly 1% below fair

        bell.claim(id);
        assertEq(stock.balanceOf(seat.vaultOf(id)), 4.9005e18, "minOut boundary accepted");
    }

    /// Fails open: outside the US session there is no verifiable equity price -> base delivered.
    function test_FallbackOffSession() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(stock));

        vm.warp(MON_IN_SESSION + 8 hours); // 23:00 UTC — after close, feeds still fresh
        bell.claim(id);
        assertEq(usdg.balanceOf(seat.vaultOf(id)), 990e18, "base delivered off-hours");
        assertEq(stock.balanceOf(seat.vaultOf(id)), 0);
    }

    /// Fails open: silent feed (staleness bound exceeded) -> base delivered.
    function test_FallbackStaleFeed() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(stock));

        vm.warp(MON_IN_SESSION + 2 days); // Wednesday in-session, but no feed update for 48h > 25h bound
        bell.claim(id);
        assertEq(usdg.balanceOf(seat.vaultOf(id)), 990e18, "base delivered on silent oracle");
    }

    /// Preference auth: only the Seat's owner sets it; only supported tokens; base always allowed.
    function test_SetPayoutTokenAuth() public {
        uint256 id = seat.mint(alice);

        vm.prank(bob);
        vm.expectRevert(Bell.NotSeatOwner.selector);
        bell.setPayoutToken(id, address(stock));

        vm.prank(alice);
        vm.expectRevert(Bell.UnsupportedPayoutToken.selector);
        bell.setPayoutToken(id, address(0xDECAF));

        vm.startPrank(alice);
        bell.setPayoutToken(id, address(stock));
        assertEq(bell.payoutTokenOf(id), address(stock));
        bell.setPayoutToken(id, address(0)); // back to base — always allowed
        assertEq(bell.payoutTokenOf(id), address(0));
        vm.stopPrank();
    }

    /// The preference is per-owner: transferring the Seat clears it (buyer chooses their own).
    function test_TransferClearsPayoutPreference() public {
        uint256 id = _oneSeatRung();
        vm.prank(alice);
        bell.setPayoutToken(id, address(stock));

        vm.prank(alice);
        seat.transferFrom(alice, bob, id);
        assertEq(bell.payoutTokenOf(id), address(0), "preference cleared on transfer");

        bell.claim(id);
        assertEq(usdg.balanceOf(seat.vaultOf(id)), 990e18, "claims pay base after clear");
    }

    /// The registry is append-only and registrar-gated: no re-listing, no feed swaps under users.
    function test_RegistryAppendOnlyAndGated() public {
        ERC20Mock other = new ERC20Mock();
        vm.prank(bob);
        vm.expectRevert(StockConverter.NotRegistrar.selector);
        conv.listStock(address(other), AggregatorV3Interface(address(stockFeed)), 3000);

        vm.expectRevert(StockConverter.AlreadyListed.selector);
        conv.listStock(address(stock), AggregatorV3Interface(address(baseFeed)), 500);

        assertFalse(conv.isSupported(address(usdg)), "base is not a conversion target");
    }

    /// Defense-in-depth: even a converter that returns success while under-pulling leaves the Bell with
    /// ZERO standing allowance — so it can never later drain the pot or other Seats' reserved rewards.
    function test_NoDanglingAllowanceOnUnderpullingConverter() public {
        UnderpullingConverter rogue = new UnderpullingConverter(usdg);
        Seat freshSeat = new Seat("S", "S", 10, address(this)); // its own hook slot
        Bell rogueBell = new Bell(ISeatLike(address(freshSeat)), essey, usdg, treasury, 100e18, 100, fees, weights, rogue, address(0));
        freshSeat.setHook(address(rogueBell));

        uint256 id = freshSeat.mint(alice);
        vm.startPrank(alice);
        essey.approve(address(rogueBell), type(uint256).max);
        rogueBell.activate(id, 1);
        rogueBell.setPayoutToken(id, address(stock)); // rogue.isSupported returns true
        vm.stopPrank();
        usdg.mint(address(rogueBell), 1000e18);
        rogueBell.ring();

        rogueBell.claim(id);
        assertEq(usdg.allowance(address(rogueBell), address(rogue)), 0, "no standing allowance after success");
    }

    /// Direct convert guards: zero amount and unlisted tokens revert.
    function test_ConvertGuards() public {
        vm.expectRevert(StockConverter.ZeroAmount.selector);
        conv.convert(0, address(stock), alice);

        vm.expectRevert(StockConverter.NotListed.selector);
        conv.convert(1e18, address(0xDECAF), alice);
    }
}
