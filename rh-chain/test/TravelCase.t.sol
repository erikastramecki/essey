// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {TravelVoucher} from "../src/travel/TravelVoucher.sol";
import {TravelCase} from "../src/travel/TravelCase.sol";

contract MockUSDG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}
    function decimals() public pure override returns (uint8) { return 6; } // real USDG is 6-dec
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// A stray ERC721 that is NOT the voucher collection — used to prove the raffle rejects junk NFTs.
contract JunkNFT is ERC721 {
    constructor() ERC721("Junk", "JUNK") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract TravelCaseTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    MockUSDG usdg; // base/reward + voucher backing
    ERC20Mock essey; // the access token
    Seat seat;
    Bell bell;
    TravelVoucher voucher;
    TravelCase rc;

    address treasury = address(0x7EA);
    address travelSwap = address(0x7A5E);
    address feeSink; // == address(bell)
    address keeper = address(0xBEEF);
    address alice = address(0xA11CE);

    // this test contract is both the voucher issuer and the raffle bankroll
    uint8 constant TIER_A = 1; // $1,500
    uint8 constant TIER_B = 2; // $5,000 (the jackpot tier)
    uint256 constant VAL_A = 1_500e6;
    uint256 constant VAL_B = 5_000e6;

    uint256 constant CASE_PRICE = 200e18; // in ESSEY
    uint256 constant BUY_FEE = 30e6; // in USDG (base, 6-dec)
    uint256 constant BOOSTER_BPS = 6_000; // 60% of the buy fee to the Bell

    function setUp() public {
        vm.roll(1000); // realistic base block so the 256-block window math never underflows
        usdg = new MockUSDG();
        essey = new ERC20Mock();
        seat = new Seat("Essey Seat", "SEAT", 2222, address(this));

        uint256[] memory fees = new uint256[](1);
        uint256[] memory weights = new uint256[](1);
        fees[0] = 1e18;
        weights[0] = 1;
        bell = new Bell(seat, essey, usdg, treasury, 100e18, 100, fees, weights, IConverter(address(0)), address(0));
        feeSink = address(bell);

        // issuer = this, admin = this, spread 5%, spread sink = the Bell (TravelSwap's fee farm)
        voucher = new TravelVoucher("Essey Travel Voucher", "TRIP", IERC20(address(usdg)), travelSwap, address(this), address(this), 500, feeSink);
        voucher.setTier(TIER_A, VAL_A);
        voucher.setTier(TIER_B, VAL_B);

        rc = new TravelCase(
            IERC20(address(essey)), bell, IERC721(address(voucher)), treasury, address(this), CASE_PRICE, BUY_FEE, BOOSTER_BPS, keeper
        );

        // fund backing for minting vouchers, and approve the raffle to pull them on seed
        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(voucher), type(uint256).max);
        voucher.setApprovalForAll(address(rc), true);
    }

    /// Mint `count` vouchers of `tier` to this bankroll and seed them into the raffle. Returns their ids.
    function _seed(uint8 tier, uint256 count) internal returns (uint256[] memory ids) {
        uint256 fromId = voucher.issue(tier, count, address(this)); // minted to the bankroll (this)
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) ids[i] = fromId + i;
        rc.seed(ids);
    }

    function _fundBuyer(address who) internal {
        essey.mint(who, 10_000e18);
        usdg.mint(who, 10_000e6);
        vm.startPrank(who);
        essey.approve(address(rc), type(uint256).max);
        usdg.approve(address(rc), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- inventory / seeding

    function test_seedMovesVouchersIntoInventory() public {
        uint256[] memory ids = _seed(TIER_A, 3);
        assertEq(rc.inventoryCount(), 3);
        assertEq(rc.freeInventory(), 3);
        assertEq(voucher.ownerOf(ids[0]), address(rc), "raffle custodies the prize");
    }

    function test_onlyBankrollSeeds() public {
        uint256 fromId = voucher.issue(TIER_A, 1, address(this));
        uint256[] memory ids = new uint256[](1);
        ids[0] = fromId;
        vm.prank(alice);
        vm.expectRevert(TravelCase.NotBankroll.selector);
        rc.seed(ids);
    }

    function test_rejectsForeignNFTs() public {
        JunkNFT junk = new JunkNFT();
        junk.mint(address(this), 1);
        vm.expectRevert(TravelCase.WrongCollection.selector);
        junk.safeTransferFrom(address(this), address(rc), 1); // hook rejects a non-voucher collection
    }

    // ---------------------------------------------------------------- buy backing invariant + fees

    function test_buyRevertsWithoutBackingInventory() public {
        _fundBuyer(alice);
        vm.prank(alice);
        vm.expectRevert(TravelCase.NoBackingInventory.selector);
        rc.buy(); // empty inventory
    }

    function test_buyChargesEsseyToTreasuryAndSplitsFeeToBell() public {
        _seed(TIER_A, 1);
        _fundBuyer(alice);

        uint256 potBefore = usdg.balanceOf(address(bell));
        vm.prank(alice);
        rc.buy();

        assertEq(essey.balanceOf(treasury), CASE_PRICE, "access token sunk to treasury");
        assertEq(usdg.balanceOf(address(bell)) - potBefore, (BUY_FEE * BOOSTER_BPS) / 10_000, "60% of fee -> Bell");
        assertEq(usdg.balanceOf(treasury), (BUY_FEE * (10_000 - BOOSTER_BPS)) / 10_000, "40% of fee -> treasury");
        assertEq(rc.unopened(), 1);
        assertEq(rc.freeInventory(), 0, "the sole voucher is now spoken for");
    }

    function test_cannotOverbuyBeyondBacking() public {
        _seed(TIER_A, 1);
        _fundBuyer(alice);
        vm.startPrank(alice);
        rc.buy(); // consumes the only backing
        vm.expectRevert(TravelCase.NoBackingInventory.selector);
        rc.buy(); // second buy has no free voucher
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- draw / delivery

    function test_openDeliversAVoucherToBuyer_thenWinnerRedeems() public {
        _seed(TIER_A, 1);
        _fundBuyer(alice);

        vm.prank(alice);
        uint256 caseId = rc.buy();
        vm.roll(block.number + 2); // move past drawBlock so blockhash is live
        vm.prank(alice);
        uint256 wonId = rc.open(caseId);

        assertEq(voucher.ownerOf(wonId), alice, "the drawn voucher is delivered to the buyer");
        assertEq(rc.inventoryCount(), 0, "prize left inventory");
        assertEq(rc.unopened(), 0);

        // The winner redeems the voucher itself — backing flows to TravelSwap (the manual booking funder).
        vm.prank(alice);
        voucher.redeem(wonId);
        assertEq(usdg.balanceOf(travelSwap), VAL_A, "the trip is funded on redemption");
    }

    function test_winnerCanSellBackTheDrawnVoucherToTheBell() public {
        _seed(TIER_A, 1);
        _fundBuyer(alice);
        vm.prank(alice);
        uint256 caseId = rc.buy();
        vm.roll(block.number + 2);
        vm.prank(alice);
        uint256 wonId = rc.open(caseId);

        uint256 potBefore = usdg.balanceOf(address(bell));
        vm.prank(alice);
        uint256 paid = voucher.sellBack(wonId);
        assertEq(paid, VAL_A - (VAL_A * 500) / 10_000, "value minus the 5% locked spread");
        assertEq(usdg.balanceOf(address(bell)) - potBefore, (VAL_A * 500) / 10_000, "spread farms the Bell");
    }

    function test_keeperCanOpenOnBuyersBehalf_prizeToBuyer() public {
        _seed(TIER_A, 1);
        _fundBuyer(alice);
        vm.prank(alice);
        uint256 caseId = rc.buy();
        vm.roll(block.number + 2);
        vm.prank(keeper);
        uint256 wonId = rc.open(caseId);
        assertEq(voucher.ownerOf(wonId), alice, "keeper reveals; prize still goes to the buyer");
    }

    function test_strangerCannotOpen() public {
        _seed(TIER_A, 1);
        _fundBuyer(alice);
        vm.prank(alice);
        uint256 caseId = rc.buy();
        vm.roll(block.number + 2);
        vm.prank(address(0xBAD));
        vm.expectRevert(TravelCase.NotYourCase.selector);
        rc.open(caseId);
    }

    // ---------------------------------------------------------------- expiry: floor + sweep

    function test_expiredClaimPaysTheLowestValueVoucher() public {
        // pool has one $5,000 and one $1,500 voucher; an expired case can only claim the floor ($1,500)
        _seed(TIER_B, 1);
        uint256[] memory lowIds = _seed(TIER_A, 1);
        _fundBuyer(alice);

        vm.prank(alice);
        uint256 caseId = rc.buy();
        vm.roll(block.number + 300); // draw block out of the 256-block window
        vm.prank(alice);
        uint256 gotId = rc.claimExpired(caseId);

        assertEq(gotId, lowIds[0], "abandoning the draw yields the floor, never the jackpot");
        assertEq(voucher.lockedValue(gotId), VAL_A);
        assertEq(voucher.ownerOf(gotId), alice);
    }

    function test_openRevertsOnceExpired() public {
        _seed(TIER_A, 1);
        _fundBuyer(alice);
        vm.prank(alice);
        uint256 caseId = rc.buy();
        vm.roll(block.number + 300);
        vm.prank(alice);
        vm.expectRevert(TravelCase.DrawExpired.selector);
        rc.open(caseId);
    }

    function test_sweepAbandonedFreesBackingAfterTTL() public {
        _seed(TIER_A, 1);
        _fundBuyer(alice);
        vm.prank(alice);
        uint256 caseId = rc.buy();
        vm.roll(block.number + 300);
        // before the TTL, sweep is not allowed
        vm.expectRevert(TravelCase.DrawNotExpired.selector);
        rc.sweepAbandoned(caseId);
        // after the TTL anyone may free the backing; the voucher stays in the pool
        vm.warp(block.timestamp + 7 days + 1);
        rc.sweepAbandoned(caseId);
        assertEq(rc.unopened(), 0, "backing freed");
        assertEq(rc.inventoryCount(), 1, "the unclaimed prize remains drawable");
        assertEq(rc.freeInventory(), 1);
    }

    // ---------------------------------------------------------------- backing invariant under a mixed run

    /// Across a run of seeds/buys/opens the raffle is never over-sold: unopened Cases never exceed inventory.
    function test_backingInvariantHoldsAcrossAMixedRun() public {
        _seed(TIER_A, 4);
        _seed(TIER_B, 2);
        _fundBuyer(alice);

        uint256 opened;
        for (uint256 i = 0; i < 6; i++) {
            assertGe(rc.inventoryCount(), rc.unopened(), "never over-sold");
            vm.prank(alice);
            uint256 caseId = rc.buy();
            vm.roll(block.number + 2);
            vm.prank(alice);
            rc.open(caseId);
            opened++;
        }
        assertEq(opened, 6);
        assertEq(rc.inventoryCount(), 0, "all prizes drawn");
        // no free backing left → the next buy reverts
        vm.prank(alice);
        vm.expectRevert(TravelCase.NoBackingInventory.selector);
        rc.buy();
    }
}
