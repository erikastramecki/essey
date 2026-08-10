// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell} from "../src/market/Bell.sol";
import {TravelVoucher} from "../src/travel/TravelVoucher.sol";
import {TravelCase} from "../src/travel/TravelCase.sol";
import {BackedAssetFactory} from "../src/travel/BackedAssetFactory.sol";

contract MockUSDG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract BackedAssetFactoryTest is Test {
    MockUSDG usdg;
    ERC20Mock essey;
    Seat seat;
    Bell bell;
    BackedAssetFactory factory;

    address treasury = address(0x7EA);
    address coinVoyage = address(0xC0FFEE); // an operator (a company)
    address jane = address(0xDA9E); // an operator (an individual)
    address settlement = address(0x5E77); // an operator's fulfilment wallet
    address feeWallet = address(0xFEE5);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.roll(1000);
        usdg = new MockUSDG();
        essey = new ERC20Mock();
        seat = new Seat("Essey Seat", "SEAT", 2222, address(this));
        uint256[] memory fees = new uint256[](1);
        uint256[] memory weights = new uint256[](1);
        fees[0] = 1e18;
        weights[0] = 1;
        bell = new Bell(seat, essey, usdg, treasury, 100e18, 100, fees, weights, IConverter(address(0)), address(0));

        factory = new BackedAssetFactory(IERC20(address(usdg)), IERC20(address(essey)), bell, treasury);
    }

    // ---------------------------------------------------------------- launch a product

    function test_launchDeploysAnOperatorOwnedBackedVoucher() public {
        vm.prank(coinVoyage);
        address v = factory.launch("CoinVoyage Travel Voucher", "CVTRIP", settlement, 500, feeWallet);

        TravelVoucher voucher = TravelVoucher(v);
        assertEq(voucher.issuer(), coinVoyage, "operator is the issuer");
        assertEq(voucher.admin(), coinVoyage, "operator is the admin");
        assertEq(voucher.travelSwap(), settlement, "settlement wired");
        assertEq(voucher.spreadRecipient(), feeWallet, "fee wallet wired");
        assertEq(address(voucher.usdg()), address(usdg), "shared backing stable");
        assertEq(voucher.name(), "CoinVoyage Travel Voucher", "per-operator brand");
        assertEq(voucher.symbol(), "CVTRIP");

        assertEq(factory.productCount(), 1);
        assertTrue(factory.isFactoryVoucher(v));
        assertEq(factory.productsOfCount(coinVoyage), 1);
        (address rv, address rop, string memory rname,) = factory.products(0);
        assertEq(rv, v);
        assertEq(rop, coinVoyage);
        assertEq(rname, "CoinVoyage Travel Voucher");
    }

    function test_launchesAreIsolatedPerOperator() public {
        vm.prank(coinVoyage);
        address v1 = factory.launch("CoinVoyage", "CV", settlement, 500, feeWallet);
        vm.prank(jane);
        address v2 = factory.launch("Jane's Passes", "JANE", settlement, 300, feeWallet);

        assertTrue(v1 != v2, "each operator gets a fresh, isolated contract");
        assertEq(factory.productsOfCount(coinVoyage), 1);
        assertEq(factory.productsOfCount(jane), 1);
        assertEq(factory.productCount(), 2);
        // one operator is issuer/admin of only their own voucher
        assertEq(TravelVoucher(v1).admin(), coinVoyage);
        assertEq(TravelVoucher(v2).admin(), jane);
    }

    function test_launchRejectsBadConfigAtDeploy() public {
        vm.startPrank(coinVoyage);
        vm.expectRevert(TravelVoucher.ZeroAddress.selector);
        factory.launch("X", "X", address(0), 500, feeWallet); // zero settlement
        vm.expectRevert(TravelVoucher.BadSpread.selector);
        factory.launch("X", "X", settlement, 2_001, feeWallet); // spread over the 20% cap
        vm.stopPrank();
        assertEq(factory.productCount(), 0, "no broken product registered");
    }

    // ---------------------------------------------------------------- launch a raffle

    function test_launchRaffleOnlyForAFactoryVoucher() public {
        vm.prank(coinVoyage);
        vm.expectRevert(BackedAssetFactory.NotFactoryVoucher.selector);
        factory.launchRaffle(address(0xDEAD), 100e18, 5e6, 6_000, address(0));
    }

    /// Only the voucher's operator (its issuer) may stand up a raffle for it — no branding-spoof by a stranger.
    function test_launchRaffleRejectsNonOperator() public {
        vm.prank(coinVoyage);
        address v = factory.launch("CoinVoyage", "CV", settlement, 500, feeWallet);
        vm.prank(jane); // jane is not the operator of coinVoyage's voucher
        vm.expectRevert(BackedAssetFactory.NotOperator.selector);
        factory.launchRaffle(v, 200e18, 30e6, 6_000, jane);
    }

    function test_constructorRejectsEsseyEqualToRewardToken() public {
        // bell.reward() == usdg here, so passing usdg as the access token must fail fast at deploy.
        vm.expectRevert(BackedAssetFactory.EsseyIsRewardToken.selector);
        new BackedAssetFactory(IERC20(address(usdg)), IERC20(address(usdg)), bell, treasury);
    }

    function test_launchRaffleWiresIntoSharedEconomy() public {
        vm.startPrank(coinVoyage);
        address v = factory.launch("CoinVoyage", "CV", settlement, 500, feeWallet);
        address c = factory.launchRaffle(v, 200e18, 30e6, 6_000, coinVoyage);
        vm.stopPrank();

        TravelCase rc = TravelCase(c);
        assertEq(address(rc.voucher()), v, "raffle draws the operator's voucher");
        assertEq(address(rc.essey()), address(essey), "priced in the shared access token");
        assertEq(address(rc.bell()), address(bell), "buy fee feeds the shared Bell");
        assertEq(rc.treasury(), treasury, "shared treasury");
        assertEq(rc.bankroll(), coinVoyage, "operator is the raffle bankroll");
        assertEq(factory.raffleCount(), 1);
        assertEq(factory.rafflesOfCount(coinVoyage), 1);
    }

    // ---------------------------------------------------------------- end-to-end self-serve launch

    function test_fullSelfServeLaunch_backing_seed_buy_open() public {
        // 1. Operator launches a $250 line + a Gotcha box for it.
        vm.startPrank(coinVoyage);
        address v = factory.launch("CoinVoyage Travel Voucher", "CVTRIP", settlement, 500, feeWallet);
        address c = factory.launchRaffle(v, 200e18, 30e6, 6_000, coinVoyage);
        TravelVoucher voucher = TravelVoucher(v);
        TravelCase rc = TravelCase(c);

        // 2. Define the $250 tier, fund backing, mint 3 vouchers (money leaves the operator's wallet).
        voucher.setTier(1, 250e6);
        vm.stopPrank();
        usdg.mint(coinVoyage, 750e6);
        vm.startPrank(coinVoyage);
        usdg.approve(v, type(uint256).max);
        uint256 fromId = voucher.issue(1, 3, coinVoyage);
        assertEq(voucher.reserve(), 750e6, "3 x $250 backing held");

        // 3. Seed the box.
        voucher.setApprovalForAll(c, true);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) ids[i] = fromId + i;
        rc.seed(ids);
        vm.stopPrank();
        assertEq(rc.inventoryCount(), 3, "prizes live in the box");

        // 4. A player buys a case and opens a $250 voucher.
        essey.mint(alice, 1_000e18);
        usdg.mint(alice, 1_000e6);
        vm.startPrank(alice);
        essey.approve(c, type(uint256).max);
        usdg.approve(c, type(uint256).max);
        uint256 caseId = rc.buy();
        vm.roll(block.number + 2);
        uint256 won = rc.open(caseId);
        vm.stopPrank();
        assertEq(voucher.ownerOf(won), alice, "winner holds a real, backed $250 voucher");

        // 5. Winner redeems: the $250 backing funds the trip at the operator's settlement wallet.
        vm.prank(alice);
        voucher.redeem(won);
        assertEq(usdg.balanceOf(settlement), 250e6, "redemption funds the booking");
    }
}
