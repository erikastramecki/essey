// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Don} from "../src/market/Don.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";

/// DonReserve backed by the REAL Don (not a mock), so the cap-pinning, transfer-hook, and
/// membership-forfeit properties are proven against the contract that ships.
contract DonReserveTest is Test {
    ERC20Mock essey;
    Don don;
    DonReserve res;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant CAP = 8; // small cap keeps the solvency loops cheap

    uint256[] fees = [100e18, 250e18, 500e18, 1500e18];
    uint256[] weights = [100, 160, 200, 333];

    function setUp() public {
        essey = new ERC20Mock();
        don = new Don("Essey Don", "DON", CAP, address(this)); // test = minter
        res = new DonReserve(IERC20(address(essey)), IERC721(address(don)));
    }

    function _fund(uint256 amt) internal {
        essey.mint(address(this), amt);
        essey.approve(address(res), amt);
        res.fund(amt);
    }

    function _mintTo(address who) internal returns (uint256 id) {
        id = don.mint(who, keccak256(abi.encode(don.totalMinted() + 1)));
        vm.prank(who);
        don.approve(address(res), id);
    }

    // ---------------------------------------------------------------- cap pinning

    function test_BackedSupplyPinnedToDonCapOnChain() public view {
        assertEq(res.backedSupply(), CAP, "backedSupply read from Don.maxSupply, not a constructor arg");
    }

    function test_CannotMintPastBackedSupply_theftImpossible() public {
        for (uint256 i = 0; i < CAP; i++) _mintTo(alice);
        vm.expectRevert(Don.SoldOut.selector);
        don.mint(alice, keccak256("one too many"));
    }

    // ---------------------------------------------------------------- floor mechanics

    function test_FloorRisesWithFundingAndDonations() public {
        assertEq(res.floorPerDon(), 0);
        _fund(CAP * 100);
        assertEq(res.floorPerDon(), 100, "reserve / backedSupply");
        essey.mint(address(this), CAP * 50);
        essey.transfer(address(res), CAP * 50); // plain donation counts too
        assertEq(res.floorPerDon(), 150, "floor only ever rises");
    }

    function test_RedeemPaysFloor_locksDon_dropsBackedSupply() public {
        _fund(CAP * 300_000e18);
        uint256 id = _mintTo(alice);

        vm.prank(alice);
        uint256 paid = res.redeem(id);

        assertEq(paid, 300_000e18, "the advertised 300k floor");
        assertEq(essey.balanceOf(alice), paid);
        assertEq(don.ownerOf(id), address(res), "Don locked in the reserve forever");
        assertEq(res.backedSupply(), CAP - 1);
        assertEq(res.floorPerDon(), 300_000e18, "floor unchanged for everyone else (pro-rata invariant)");
    }

    function test_RedeemGuards() public {
        _fund(CAP * 10);
        uint256 id = _mintTo(alice);

        vm.prank(bob);
        vm.expectRevert(DonReserve.NotDonOwner.selector);
        res.redeem(id);

        uint256 unapproved = don.mint(alice, keccak256("unapproved"));
        vm.prank(alice);
        vm.expectRevert(); // ERC721InsufficientApproval
        res.redeem(unapproved);
    }

    function test_ThinReserveRefusesButRecovers() public {
        _fund(CAP - 1); // floor = 0
        uint256 id = _mintTo(alice);
        vm.prank(alice);
        vm.expectRevert(DonReserve.NoFloor.selector);
        res.redeem(id);

        _fund(CAP); // permissionless top-up unblocks
        vm.prank(alice);
        assertGt(res.redeem(id), 0);
    }

    /// Total paid across every redemption never exceeds funding; the floor never decreases mid-sequence.
    function test_ExactSolvencyAcrossFullRedemption() public {
        _fund(1000);
        uint256 totalPaid;
        uint256 prevFloor;
        for (uint256 i = 0; i < CAP; i++) {
            uint256 floorNow = res.floorPerDon();
            assertGe(floorNow, prevFloor, "floor never drops for remaining holders");
            prevFloor = floorNow;
            uint256 id = _mintTo(alice);
            vm.prank(alice);
            totalPaid += res.redeem(id);
        }
        assertLe(totalPaid, 1000, "never over-paid");
        assertEq(totalPaid + res.reserve(), 1000, "conservation: paid + dust left == funded");
        assertEq(res.backedSupply(), 0);
        vm.expectRevert(DonReserve.NothingBacked.selector);
        res.redeem(1);
    }

    /// Redemption forfeits membership: the Don's transfer INTO the reserve fires the Bell hook, clearing
    /// its tier mid-redeem — and the redeem still settles (the hook is safe to run in that window).
    function test_RedeemForfeitsBellMembership() public {
        Bell bell = new Bell(
            ISeatLike(address(don)), essey, new ERC20Mock(), address(0x7EA), 100e18, 0, fees, weights,
            IConverter(address(0)), address(0)
        );
        don.setHook(address(bell));

        _fund(CAP * 1000e18);
        uint256 id = _mintTo(alice);
        essey.mint(alice, 100e18);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(id, 1);
        assertEq(bell.totalWeight(), 100);

        res.redeem(id);
        vm.stopPrank();

        (uint8 tier,,,) = bell.seats(id);
        assertEq(tier, 0, "tier cleared - the redeemed Don is off the payout roll");
        assertEq(bell.totalWeight(), 0);
        assertEq(don.ownerOf(id), address(res));
        assertEq(essey.balanceOf(alice), 1000e18, "floor paid despite the hook firing mid-redeem");
    }

    /// No sequence of funding + redemptions pays out more than funded, floor monotone under mid-stream funding.
    function testFuzz_SolventAndNonDecreasing(uint96 fundAmt, uint8 redeems, uint96 midFund) public {
        uint256 amt = uint256(bound(fundAmt, 1, 1e24));
        _fund(amt);
        uint256 totalIn = amt;

        uint256 r = uint256(bound(redeems, 0, CAP));
        uint256 prevFloor;
        uint256 totalPaid;
        for (uint256 i = 0; i < r; i++) {
            if (i == r / 2 && midFund > 0) {
                _fund(midFund);
                totalIn += midFund;
            }
            uint256 floorNow = res.floorPerDon();
            if (floorNow == 0) break;
            assertGe(floorNow, prevFloor, "floor monotonically non-decreasing");
            prevFloor = floorNow;
            uint256 id = _mintTo(alice);
            vm.prank(alice);
            totalPaid += res.redeem(id);
        }
        assertLe(totalPaid, totalIn, "never pays out more than was funded");
        assertEq(res.reserve(), totalIn - totalPaid, "reserve accounting exact");
    }
}
