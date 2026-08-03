// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell} from "../src/market/Bell.sol";
import {EsseyExchange} from "../src/market/EsseyExchange.sol";
import {EsseyToken} from "../src/market/EsseyToken.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract EsseyExchangeTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector; // the test seeds Seats minted to itself
    }

    Seat seat;
    EsseyToken essey;
    ERC20Mock usdg; // Bell reward == Exchange fee token
    Bell bell;
    EsseyExchange ex;

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant PRICE = 500e18; // $ESSEY per Seat
    uint256 constant SWAP_FEE = 10e18; // USDG
    uint256 constant SNIPE_FEE = 15e18;
    uint256 constant SELL_FEE = 8e18;

    function setUp() public {
        seat = new Seat("Essey Seat", "SEAT", 2222, address(this));
        essey = new EsseyToken(address(this)); // this test holds all supply, distributes it
        usdg = new ERC20Mock();

        uint256[] memory fees = new uint256[](1);
        fees[0] = 100e18;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;
        bell = new Bell(seat, essey, usdg, treasury, 1e18, 100, fees, weights, IConverter(address(0)), address(0));
        seat.setHook(address(bell));

        ex = new EsseyExchange(
            IERC721(address(seat)), essey, bell, treasury, address(this), PRICE, SWAP_FEE, SNIPE_FEE, SELL_FEE, 7000
        );

        // Seed the Exchange with 5 Seats (ids 1..5) as float.
        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = seat.mint(address(this));
        }
        seat.setApprovalForAll(address(ex), true);
        ex.seed(ids);

        // Fund alice with $ESSEY (price) and USDG (fees), approvals set.
        essey.transfer(alice, 10_000e18);
        usdg.mint(alice, 10_000e18);
        vm.startPrank(alice);
        essey.approve(address(ex), type(uint256).max);
        usdg.approve(address(ex), type(uint256).max);
        vm.stopPrank();
    }

    function test_SeedBuildsInventory() public view {
        assertEq(ex.inventoryCount(), 5);
        assertTrue(ex.inInventory(3));
        assertEq(seat.ownerOf(1), address(ex), "Exchange holds the float");
    }

    /// Buy: pay price in $ESSEY + swap fee in USDG; receive the next Seat; fee splits 70/30 and the
    /// booster share grows the Bell's pot.
    function test_BuyDeliversSeatAndFeedsBell() public {
        uint256 potBefore = bell.pot();
        vm.prank(alice);
        uint256 id = ex.buy();

        assertEq(id, 5, "LIFO: next Seat is the last seeded");
        assertEq(seat.ownerOf(id), alice, "buyer owns the Seat");
        assertEq(ex.inventoryCount(), 4);
        assertEq(ex.esseyReserve(), PRICE, "price added to reserve");
        // Fee 10 USDG: 7 to Bell, 3 to treasury.
        assertEq(bell.pot() - potBefore, 7e18, "booster share grew the pot");
        assertEq(usdg.balanceOf(treasury), 3e18, "protocol share to treasury");
        assertEq(essey.balanceOf(alice), 10_000e18 - PRICE);
    }

    /// Snipe: pick a specific Seat # at the premium fee.
    function test_SnipeSpecificSeat() public {
        uint256 potBefore = bell.pot();
        vm.prank(alice);
        ex.snipe(2);

        assertEq(seat.ownerOf(2), alice, "sniped the chosen #");
        assertFalse(ex.inInventory(2));
        assertEq(ex.inventoryCount(), 4);
        assertEq(bell.pot() - potBefore, 10.5e18, "70% of the 15 snipe fee to the pot");
        assertEq(usdg.balanceOf(treasury), 4.5e18);
    }

    /// Sell: return a Seat, receive the flat price back from the reserve, pay the sell fee.
    function test_SellReturnsPriceFromReserve() public {
        // First a buy so the reserve holds $ESSEY to pay the seller.
        vm.prank(alice);
        uint256 id = ex.buy(); // alice now owns id 5, reserve = PRICE

        vm.startPrank(alice);
        seat.approve(address(ex), id);
        uint256 esseyBefore = essey.balanceOf(alice);
        uint256 potBefore = bell.pot();
        ex.sell(id);
        vm.stopPrank();

        assertEq(essey.balanceOf(alice) - esseyBefore, PRICE, "seller paid the flat price");
        assertEq(seat.ownerOf(id), address(ex), "Seat back in inventory");
        assertTrue(ex.inInventory(id));
        assertEq(ex.esseyReserve(), 0, "reserve drained back out");
        assertEq(bell.pot() - potBefore, (SELL_FEE * 7000) / 10000, "sell fee also feeds the Bell");
    }

    /// The fees the Exchange routes actually pay out at the Bell: seed a trade, activate, ring, claim.
    function test_ExchangeFeesDistributeThroughBell() public {
        vm.prank(alice);
        uint256 id = ex.buy(); // 7 USDG into the pot

        // alice activates her new Seat and claims the fee she (and others) generated.
        essey.transfer(alice, 1_000e18);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(id, 1);
        vm.stopPrank();

        bell.ring(); // pot 7, tip 1% = 0.07, distributed 6.93 to the sole active Seat
        bell.claim(id);
        assertEq(usdg.balanceOf(seat.vaultOf(id)), 6.93e18, "Exchange-sourced fee reached the Vault");
    }

    // ---------------------------------------------------------------- guards

    function test_OnlySeederSeeds() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(bob);
        vm.expectRevert(EsseyExchange.NotSeeder.selector);
        ex.seed(ids);
    }

    function test_BuyEmptyInventoryReverts() public {
        // Drain all 5.
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            ex.buy();
        }
        vm.expectRevert(EsseyExchange.EmptyInventory.selector);
        ex.buy();
        vm.stopPrank();
    }

    function test_SnipeAbsentReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EsseyExchange.NotInInventory.selector, 99));
        ex.snipe(99);
    }

    function test_SellWithoutReserveReverts() public {
        // No buys yet -> reserve is 0 -> paying the seller their $ESSEY fails.
        uint256 id = seat.mint(bob);
        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        seat.approve(address(ex), id);
        usdg.approve(address(ex), type(uint256).max);
        vm.expectRevert(); // ERC20 insufficient balance on the reserve payout
        ex.sell(id);
        vm.stopPrank();
    }

    function test_ConfigGuards() public {
        // snipeFee < swapFee rejected.
        vm.expectRevert(EsseyExchange.BadConfig.selector);
        new EsseyExchange(
            IERC721(address(seat)), essey, bell, treasury, address(this), PRICE, 20e18, 10e18, SELL_FEE, 7000
        );
        // price token == fee token (reward) rejected: make a Bell whose reward IS essey.
        Bell esseyRewardBell;
        {
            uint256[] memory f = new uint256[](1);
            f[0] = 1e18;
            uint256[] memory w = new uint256[](1);
            w[0] = 1;
            esseyRewardBell = new Bell(seat, usdg, essey, treasury, 1e18, 100, f, w, IConverter(address(0)), address(0));
        }
        vm.expectRevert(EsseyExchange.BadConfig.selector);
        new EsseyExchange(
            IERC721(address(seat)), essey, esseyRewardBell, treasury, address(this), PRICE, SWAP_FEE, SNIPE_FEE, SELL_FEE, 7000
        );

        // Mis-wire: a Bell that rewards a DIFFERENT Seat collection is rejected — fees could otherwise
        // flow to an unrelated pot.
        Seat otherSeat = new Seat("Other", "O", 10, address(this));
        Bell otherBell;
        {
            uint256[] memory f = new uint256[](1);
            f[0] = 1e18;
            uint256[] memory w = new uint256[](1);
            w[0] = 1;
            otherBell = new Bell(otherSeat, essey, usdg, treasury, 1e18, 100, f, w, IConverter(address(0)), address(0));
        }
        vm.expectRevert(EsseyExchange.BadConfig.selector);
        new EsseyExchange(
            IERC721(address(seat)), essey, otherBell, treasury, address(this), PRICE, SWAP_FEE, SNIPE_FEE, SELL_FEE, 7000
        );
    }
}
