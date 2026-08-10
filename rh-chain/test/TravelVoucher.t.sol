// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TravelVoucher} from "../src/travel/TravelVoucher.sol";

contract MockUSDG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}
    function decimals() public pure override returns (uint8) { return 6; } // real USDG is 6-dec
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract TravelVoucherTest is Test {
    MockUSDG usdg;
    TravelVoucher v;
    address travelSwap = address(0x7A5E);
    address issuer = address(0x1550E7);
    address admin = address(0xAD);
    address feeSink = address(0xFEE5);
    address alice = address(0xA11CE);

    uint8 constant TIER = 1;
    uint256 constant VALUE = 1_500e6; // $1,500 package

    function setUp() public {
        usdg = new MockUSDG();
        v = new TravelVoucher("Essey Travel Voucher", "TRIP", IERC20(address(usdg)), travelSwap, issuer, admin, 500, feeSink); // 5% spread
        vm.prank(admin);
        v.setTier(TIER, VALUE);
        usdg.mint(issuer, 1_000_000e6);
        vm.prank(issuer);
        usdg.approve(address(v), type(uint256).max);
    }

    function _issueTo(address to, uint256 count) internal returns (uint256 fromId) {
        vm.prank(issuer);
        return v.issue(TIER, count, to);
    }

    // ---------------------------------------------------------------- issuance + backing

    function test_issueDepositsFullBacking() public {
        uint256 fromId = _issueTo(alice, 3);
        assertEq(v.reserved(), 3 * VALUE, "reserved tracks outstanding backing");
        assertEq(v.reserve(), 3 * VALUE, "the USDG backing is actually held");
        assertEq(v.ownerOf(fromId), alice);
        assertEq(v.ownerOf(fromId + 2), alice);
        assertEq(v.lockedValue(fromId), VALUE, "value locked at issue");
        assertGe(v.reserve(), v.reserved(), "solvency");
    }

    function test_onlyIssuerCanIssue() public {
        vm.prank(alice);
        vm.expectRevert(TravelVoucher.NotIssuer.selector);
        v.issue(TIER, 1, alice);
    }

    function test_cannotIssueUnsetTierOrZeroCount() public {
        vm.startPrank(issuer);
        vm.expectRevert(TravelVoucher.BadTier.selector);
        v.issue(99, 1, alice); // tier 99 unset
        vm.expectRevert(TravelVoucher.BadTier.selector);
        v.issue(TIER, 0, alice); // zero count
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- holder exits

    function test_sellBackPaysValueMinusSpread_solventThroughout() public {
        uint256 id = _issueTo(alice, 1);
        vm.prank(alice);
        uint256 paid = v.sellBack(id);
        assertEq(paid, VALUE - (VALUE * 500) / 10_000, "value minus 5% spread");
        assertEq(usdg.balanceOf(alice), paid);
        assertEq(usdg.balanceOf(feeSink), (VALUE * 500) / 10_000, "spread is house revenue");
        assertEq(v.reserved(), 0, "backing released");
        assertEq(v.reserve(), 0, "reserve drained exactly");
        assertGe(v.reserve(), v.reserved(), "solvency");
    }

    function test_redeemReleasesFullBackingToTravelSwap() public {
        uint256 id = _issueTo(alice, 1);
        vm.expectEmit(true, true, false, true, address(v));
        emit TravelVoucher.Redeemed(id, alice, TIER, VALUE);
        vm.prank(alice);
        v.redeem(id);
        assertEq(usdg.balanceOf(travelSwap), VALUE, "full backing to TravelSwap to fund the manual booking");
        assertEq(v.reserved(), 0);
        assertGe(v.reserve(), v.reserved(), "solvency");
        vm.expectRevert(); // burned
        v.ownerOf(id);
    }

    function test_onlyHolderCanExit() public {
        uint256 id = _issueTo(alice, 1);
        vm.startPrank(address(0xB0B));
        vm.expectRevert(TravelVoucher.NotHolder.selector);
        v.sellBack(id);
        vm.expectRevert(TravelVoucher.NotHolder.selector);
        v.redeem(id);
        vm.stopPrank();
    }

    /// A tier re-price never touches an already-minted voucher — its value was locked at its own issue.
    function test_tierRepriceDoesNotAffectOutstandingVouchers() public {
        uint256 id = _issueTo(alice, 1); // locked at 1500
        vm.prank(admin);
        v.setTier(TIER, 999e6); // admin drops the tier
        vm.prank(alice);
        v.redeem(id);
        assertEq(usdg.balanceOf(travelSwap), VALUE, "still redeems at the ORIGINAL locked 1500, not 999");
    }

    // ---------------------------------------------------------------- access control + bounds

    function test_onlyAdminConfigures() public {
        vm.startPrank(alice);
        vm.expectRevert(TravelVoucher.NotAdmin.selector);
        v.setTier(2, 1e6);
        vm.expectRevert(TravelVoucher.NotAdmin.selector);
        v.setSpread(100, feeSink);
        vm.stopPrank();
    }

    function test_spreadIsCapped() public {
        vm.prank(admin);
        vm.expectRevert(TravelVoucher.BadSpread.selector);
        v.setSpread(2_001, feeSink); // > 20%
        vm.expectRevert(TravelVoucher.BadSpread.selector);
        new TravelVoucher("Essey Travel Voucher", "TRIP", IERC20(address(usdg)), travelSwap, issuer, admin, 2_001, feeSink);
    }

    // ---------------------------------------------------------------- settlement-address rotation (timelocked)

    function test_travelSwapRotationIsTimelockedAndRedeemsToNewSink() public {
        uint256 id = _issueTo(alice, 1);
        address newSwap = address(0x7A5F);

        vm.prank(admin);
        v.proposeTravelSwap(newSwap);
        // Cannot commit before the timelock elapses.
        vm.expectRevert(TravelVoucher.TimelockNotElapsed.selector);
        v.commitTravelSwap();
        // Old sink is still authoritative in the window.
        assertEq(v.travelSwap(), travelSwap);

        vm.warp(block.timestamp + v.SETTLE_TIMELOCK());
        v.commitTravelSwap(); // permissionless
        assertEq(v.travelSwap(), newSwap, "settlement rotated after the timelock");

        vm.prank(alice);
        v.redeem(id);
        assertEq(usdg.balanceOf(newSwap), VALUE, "redemption funds the NEW settlement address");
        assertEq(usdg.balanceOf(travelSwap), 0, "old address gets nothing");
    }

    function test_onlyAdminProposesRotationAndNoZero() public {
        vm.prank(alice);
        vm.expectRevert(TravelVoucher.NotAdmin.selector);
        v.proposeTravelSwap(address(0x1));
        vm.prank(admin);
        vm.expectRevert(TravelVoucher.ZeroAddress.selector);
        v.proposeTravelSwap(address(0));
    }

    /// Admin can veto a pending proposal so nobody can `commit` the wrong address once its timelock elapses.
    function test_cancelTravelSwapVoidsAPendingProposal() public {
        vm.prank(admin);
        v.proposeTravelSwap(address(0xBAD));
        vm.prank(admin);
        v.cancelTravelSwap();
        vm.warp(block.timestamp + v.SETTLE_TIMELOCK());
        vm.expectRevert(TravelVoucher.TimelockNotElapsed.selector); // nothing pending → not committable
        v.commitTravelSwap();
        assertEq(v.travelSwap(), travelSwap, "settlement address unchanged");

        vm.prank(alice);
        vm.expectRevert(TravelVoucher.NotAdmin.selector);
        v.cancelTravelSwap();
    }

    // ---------------------------------------------------------------- locked spread (front-run proof)

    /// The spread is locked into the voucher at issue: raising it afterward cannot skim a holder mid-exit.
    function test_sellBackUsesSpreadLockedAtIssueNotLiveSpread() public {
        uint256 id = _issueTo(alice, 1); // locked at 5%
        vm.prank(admin);
        v.setSpread(2_000, feeSink); // admin cranks it to the 20% cap, trying to front-run alice's exit
        vm.prank(alice);
        uint256 paid = v.sellBack(id);
        assertEq(paid, VALUE - (VALUE * 500) / 10_000, "still the 5% locked at issue, not the new 20%");
    }

    // ---------------------------------------------------------------- surplus skim (donations only)

    function test_skimSurplusTakesOnlyDonationsNeverBacking() public {
        _issueTo(alice, 2); // reserved == 2*VALUE, fully backed
        usdg.mint(address(v), 777e6); // an unsolicited donation lands on the contract

        vm.prank(admin);
        uint256 skimmed = v.skimSurplus(feeSink);
        assertEq(skimmed, 777e6, "only the surplus above outstanding backing");
        assertEq(usdg.balanceOf(feeSink), 777e6);
        assertEq(v.reserve(), 2 * VALUE, "the backing is untouched");
        assertGe(v.reserve(), v.reserved(), "solvency preserved");

        // With no surplus, the skim reverts rather than dipping into backing.
        vm.prank(admin);
        vm.expectRevert(TravelVoucher.NothingToSkim.selector);
        v.skimSurplus(feeSink);
    }

    function test_onlyAdminSkims() public {
        _issueTo(alice, 1);
        usdg.mint(address(v), 1e6);
        vm.prank(alice);
        vm.expectRevert(TravelVoucher.NotAdmin.selector);
        v.skimSurplus(alice);
    }

    // ---------------------------------------------------------------- THE SOLVENCY INVARIANT (fuzz)

    /// Over any random interleaving of issue / sellBack / redeem, the reserve NEVER holds less USDG than the
    /// outstanding vouchers are owed. The house can't become insolvent; a voucher can always be settled.
    function testFuzz_reserveAlwaysCoversOutstanding(uint256 seed) public {
        uint256[] memory ids = new uint256[](64);
        uint256 n = 0;
        for (uint256 i = 0; i < 40; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = seed % 3;
            if (action == 0 && n < 60) {
                uint256 count = 1 + ((seed >> 8) % 4);
                uint256 fromId = _issueTo(alice, count);
                for (uint256 k = 0; k < count; k++) ids[n++] = fromId + k;
            } else if (action == 1 && n > 0) {
                uint256 idx = (seed >> 8) % n;
                vm.prank(alice);
                v.sellBack(ids[idx]);
                ids[idx] = ids[--n];
            } else if (n > 0) {
                uint256 idx = (seed >> 8) % n;
                vm.prank(alice);
                v.redeem(ids[idx]);
                ids[idx] = ids[--n];
            }
            // INVARIANT after every step
            assertGe(v.reserve(), v.reserved(), "reserve always covers outstanding backing");
            assertEq(v.reserved(), n * VALUE, "reserved == sum of the open vouchers' values");
        }
    }
}
