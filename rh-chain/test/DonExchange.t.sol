// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Don} from "../src/market/Don.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonExchange, IDonFloor} from "../src/market/DonExchange.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract DonExchangeTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector; // the test seeds inventory from its own balance
    }

    ERC20Mock essey;
    Don don;
    DonReserve reserve;
    DonExchange ex;

    address feeSink = address(0x51CC);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant CAP = 50;
    uint256 constant PRICE = 300_000e18; // the deploy-time floor
    uint256 constant SWAP_BPS = 800; // 8%
    uint256 constant SNIPE_BPS = 1200; // 12%
    uint256 constant STOCK_BPS = 7000; // 70% of fees -> feeSink

    function setUp() public {
        essey = new ERC20Mock();
        don = new Don("Essey Don", "DON", CAP, address(this)); // test = minter + seeder
        reserve = new DonReserve(IERC20(address(essey)), IERC721(address(don)));
        ex = new DonExchange(
            IERC721(address(don)), IERC20(address(essey)), IDonFloor(address(reserve)),
            feeSink, treasury, address(this), PRICE, SWAP_BPS, SNIPE_BPS, STOCK_BPS
        );

        essey.mint(alice, 10_000_000e18);
        essey.mint(bob, 10_000_000e18);
        vm.prank(alice);
        essey.approve(address(ex), type(uint256).max);
        vm.prank(bob);
        essey.approve(address(ex), type(uint256).max);
    }

    function _seed(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = don.mint(address(this), keccak256(abi.encode("seed", don.totalMinted() + 1)));
        }
        don.setApprovalForAll(address(ex), true);
        ex.seed(ids);
    }

    function _fundReserve(uint256 amt) internal {
        essey.mint(address(this), amt);
        essey.approve(address(reserve), amt);
        reserve.fund(amt);
    }

    // ---------------------------------------------------------------- construction

    function test_ConstructorGuards() public {
        vm.expectRevert(DonExchange.BadConfig.selector); // zero floor source
        new DonExchange(IERC721(address(don)), IERC20(address(essey)), IDonFloor(address(0)), feeSink, treasury, address(this), PRICE, SWAP_BPS, SNIPE_BPS, STOCK_BPS);
        vm.expectRevert(DonExchange.BadConfig.selector); // snipe below swap breaks the premium ordering
        new DonExchange(IERC721(address(don)), IERC20(address(essey)), IDonFloor(address(reserve)), feeSink, treasury, address(this), PRICE, 1200, 800, STOCK_BPS);
        vm.expectRevert(DonExchange.BadConfig.selector); // fee over 100%
        new DonExchange(IERC721(address(don)), IERC20(address(essey)), IDonFloor(address(reserve)), feeSink, treasury, address(this), PRICE, 800, 10_001, STOCK_BPS);
        vm.expectRevert(DonExchange.BadConfig.selector); // zero price
        new DonExchange(IERC721(address(don)), IERC20(address(essey)), IDonFloor(address(reserve)), feeSink, treasury, address(this), 0, SWAP_BPS, SNIPE_BPS, STOCK_BPS);
    }

    // ---------------------------------------------------------------- dynamic price

    function test_PriceIsFlooredAtDeployPrice() public view {
        assertEq(reserve.floorPerDon(), 0, "reserve unfunded");
        assertEq(ex.price(), PRICE, "never quotes below the seeded economics");
    }

    function test_PriceTracksRisingFloor() public {
        _fundReserve(CAP * 400_000e18); // floor 400k > 300k deploy price
        assertEq(reserve.floorPerDon(), 400_000e18);
        assertEq(ex.price(), 400_000e18, "price follows the live floor up");

        _fundReserve(CAP * 100_000e18); // floor 500k
        assertEq(ex.price(), 500_000e18, "re-read every trade, not cached");
    }

    /// THE drain this design exists to kill: with a risen floor, buying from the exchange and redeeming
    /// at the reserve must never profit. price() >= floor, plus the 8% fee, makes the loop strictly lossy.
    function test_BuyThenRedeemNeverProfits() public {
        _seed(3);
        _fundReserve(CAP * 450_000e18); // floor risen 50% above the deploy price

        uint256 cost = ex.price() + ex.feeOn(SWAP_BPS);
        uint256 before = essey.balanceOf(alice);
        vm.prank(alice);
        uint256 id = ex.buy(type(uint256).max);
        assertEq(before - essey.balanceOf(alice), cost);

        vm.startPrank(alice);
        don.approve(address(reserve), id);
        uint256 redeemed = reserve.redeem(id);
        vm.stopPrank();

        assertLt(redeemed, cost, "buy -> redeem is strictly unprofitable");
        assertGe(ex.price(), reserve.floorPerDon(), "exchange never quotes below the live floor");
    }

    /// For ANY funding level the quote can never sit below the live redemption floor.
    function testFuzz_PriceNeverBelowFloor(uint96 funding) public {
        _fundReserve(uint256(bound(funding, 1, 1e27)));
        assertGe(ex.price(), reserve.floorPerDon());
        assertGe(ex.price(), PRICE);
    }

    // ---------------------------------------------------------------- buy / snipe / sell

    function test_BuyPullsPricePlusFeeAndSplits() public {
        uint256[] memory ids = _seed(2);
        uint256 fee = (PRICE * SWAP_BPS) / 10_000; // 24k
        uint256 toStock = (fee * STOCK_BPS) / 10_000; // 16.8k
        uint256 toTreasury = fee - toStock; // 7.2k

        vm.prank(alice);
        uint256 got = ex.buy(type(uint256).max);
        assertEq(got, ids[1], "LIFO - last seeded leaves first");
        assertEq(don.ownerOf(got), alice);
        assertEq(ex.esseyReserve(), PRICE, "price stays in the desk's reserve");
        assertEq(essey.balanceOf(feeSink), toStock, "70% of the fee buys stock");
        assertEq(essey.balanceOf(treasury), toTreasury, "30% to protocol");
        assertEq(ex.inventoryCount(), 1);
        assertFalse(ex.inInventory(got));
    }

    function test_SnipePaysPremiumForSpecificDon() public {
        uint256[] memory ids = _seed(3);
        uint256 target = ids[0]; // NOT the LIFO head
        uint256 fee = (PRICE * SNIPE_BPS) / 10_000; // 36k

        uint256 before = essey.balanceOf(bob);
        vm.prank(bob);
        ex.snipe(target, type(uint256).max);
        assertEq(don.ownerOf(target), bob);
        assertEq(before - essey.balanceOf(bob), PRICE + fee);
        assertEq(essey.balanceOf(feeSink), (fee * STOCK_BPS) / 10_000);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DonExchange.NotInInventory.selector, target));
        ex.snipe(target, type(uint256).max); // already gone
    }

    function test_SellPaysPriceMinusFeeFromReserve() public {
        _seed(1);
        vm.prank(alice);
        uint256 id = ex.buy(type(uint256).max); // reserve now holds PRICE

        uint256 fee = (PRICE * SWAP_BPS) / 10_000;
        uint256 net = PRICE - fee;
        uint256 sinkBefore = essey.balanceOf(feeSink);
        uint256 before = essey.balanceOf(alice);

        vm.startPrank(alice);
        don.approve(address(ex), id);
        ex.sell(id, 0);
        vm.stopPrank();

        assertEq(essey.balanceOf(alice) - before, net, "seller nets price minus 8%");
        assertEq(essey.balanceOf(feeSink) - sinkBefore, (fee * STOCK_BPS) / 10_000, "sell fee split too");
        assertTrue(ex.inInventory(id), "Don back on the shelf");
        assertEq(ex.esseyReserve(), PRICE - net - fee, "reserve funds the payout and the fee");
    }

    function test_SellRevertsWhenDeskIlliquid() public {
        uint256 id = don.mint(alice, keccak256("outside"));
        vm.startPrank(alice);
        don.approve(address(ex), id);
        vm.expectRevert(); // ERC20InsufficientBalance — desk holds no $ESSEY yet
        ex.sell(id, 0);
        vm.stopPrank();
    }

    function test_BuyEmptyInventoryReverts() public {
        vm.prank(alice);
        vm.expectRevert(DonExchange.EmptyInventory.selector);
        ex.buy(type(uint256).max);
    }

    /// Slippage guard: a floor risen after the caller signed must not silently overcharge a buy/snipe,
    /// nor underpay a sell. The caller's bound reverts the trade instead.
    function test_SlippageBoundsProtectAgainstFloorMove() public {
        _seed(2);
        uint256 quotedCost = ex.price() + ex.feeOn(SWAP_BPS); // what alice sees at signing

        _fundReserve(CAP * 400_000e18); // floor jumps 300k -> 400k after she signed
        uint256 newCost = ex.price() + ex.feeOn(SWAP_BPS);
        assertGt(newCost, quotedCost, "cost really did rise");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DonExchange.SlippageExceeded.selector, newCost, quotedCost));
        ex.buy(quotedCost); // her stale bound protects her

        uint256 snipeCost = ex.price() + ex.feeOn(SNIPE_BPS);
        uint256 headId = ex.inventoryAt(0); // hoist the view out of the expectRevert window
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DonExchange.SlippageExceeded.selector, snipeCost, quotedCost));
        ex.snipe(headId, quotedCost);

        // At a bound that admits the new price, the trade goes through.
        vm.prank(alice);
        ex.buy(newCost);

        // Sell: a minOut above the achievable net reverts; an honest bound settles.
        _seed(1);
        vm.prank(bob);
        uint256 id = ex.buy(type(uint256).max);
        uint256 net = ex.price() - ex.feeOn(SWAP_BPS);
        vm.startPrank(bob);
        don.approve(address(ex), id);
        vm.expectRevert(abi.encodeWithSelector(DonExchange.SlippageExceeded.selector, net, net + 1));
        ex.sell(id, net + 1);
        ex.sell(id, net); // exact floor accepted
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- inventory bookkeeping

    function test_SeederOnlyAndOwnershipRequired() public {
        uint256 id = don.mint(alice, keccak256("alices"));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(alice);
        vm.expectRevert(DonExchange.NotSeeder.selector);
        ex.seed(ids);

        vm.expectRevert(); // seeder doesn't own alice's Don
        ex.seed(ids);
    }

    function test_InventoryIndexIntegrityAcrossMixedOps() public {
        uint256[] memory ids = _seed(4);
        vm.prank(alice);
        ex.snipe(ids[1], type(uint256).max); // remove from the middle — swap-and-pop
        assertEq(ex.inventoryCount(), 3);
        assertTrue(ex.inInventory(ids[0]));
        assertTrue(ex.inInventory(ids[2]));
        assertTrue(ex.inInventory(ids[3]));

        // Sell one back, then drain fully via buys — every id leaves exactly once.
        vm.startPrank(alice);
        don.approve(address(ex), ids[1]);
        ex.sell(ids[1], 0);
        bool[] memory seen = new bool[](5);
        for (uint256 i = 0; i < 4; i++) {
            uint256 got = ex.buy(type(uint256).max);
            uint256 idx = got == ids[0] ? 0 : got == ids[1] ? 1 : got == ids[2] ? 2 : got == ids[3] ? 3 : 4;
            assertLt(idx, 4, "only seeded ids come out");
            assertFalse(seen[idx], "no id delivered twice");
            seen[idx] = true;
        }
        vm.stopPrank();
        assertEq(ex.inventoryCount(), 0);
    }

    /// Fee conservation: on every trade, stock share + treasury share == the whole fee (no dust stranded).
    function testFuzz_FeeSplitConserved(uint96 funding) public {
        _fundReserve(uint256(bound(funding, 1, 1e27))); // random floor -> random odd fee amounts
        _seed(1);
        essey.mint(alice, ex.price() * 2); // enough for any fuzzed floor
        uint256 fee = ex.feeOn(SWAP_BPS);
        uint256 sinkBefore = essey.balanceOf(feeSink);
        uint256 treasBefore = essey.balanceOf(treasury);
        vm.prank(alice);
        ex.buy(type(uint256).max);
        assertEq(
            (essey.balanceOf(feeSink) - sinkBefore) + (essey.balanceOf(treasury) - treasBefore),
            fee,
            "fee fully split, nothing stranded in the desk"
        );
    }

    // ---------------------------------------------------------------- membership interaction

    /// Trading through the desk is a true ownership transfer: an activated Don sold into inventory has
    /// its tier cleared by the Bell hook, and the desk (not the seller) would have to re-activate.
    function test_SellClearsBellTier() public {
        uint256[] memory tierFees = new uint256[](1);
        tierFees[0] = 100e18;
        uint256[] memory tierWeights = new uint256[](1);
        tierWeights[0] = 100;
        Bell bell = new Bell(
            ISeatLike(address(don)), essey, new ERC20Mock(), treasury, 100e18, 0, tierFees, tierWeights,
            IConverter(address(0)), address(0)
        );
        don.setHook(address(bell));

        _seed(1);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        uint256 id = ex.buy(type(uint256).max);
        bell.activate(id, 1);
        assertEq(bell.totalWeight(), 100);

        don.approve(address(ex), id);
        ex.sell(id, 0);
        vm.stopPrank();

        (uint8 tier,,,) = bell.seats(id);
        assertEq(tier, 0, "tier cleared when the Don changed hands into the desk");
        assertEq(bell.totalWeight(), 0);
    }
}
