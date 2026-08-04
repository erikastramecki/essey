// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {EsseyCasesDegen, IEntropy, IEntropyConsumer} from "../src/market/EsseyCasesDegen.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "./RiskModules.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// Dice/Pyth-compatible entropy mock. `fulfill` invokes the consumer's EXTERNAL `_entropyCallback`
/// (the real dispatch selector) as the oracle — so the test exercises the true integration path.
contract MockEntropy is IEntropy {
    uint64 public nextSeq = 1;
    uint256 public fee;
    mapping(uint64 => address) public consumerOf;

    constructor(uint256 fee_) {
        fee = fee_;
    }

    function getFeeV2(address, uint32) external view returns (uint256) {
        return fee;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64 seq) {
        seq = nextSeq++;
        consumerOf[seq] = msg.sender;
    }

    function fulfill(uint64 seq, bytes32 random) external {
        EsseyCasesDegen(consumerOf[seq])._entropyCallback(seq, address(0), random);
    }
}

/// A contract buyer that rejects ETH — used to prove the refund path self-griefs (reverts) only.
contract RejectsEth {
    function buyOn(EsseyCasesDegen d) external payable returns (uint64) {
        return d.buy{value: msg.value}();
    }

    receive() external payable {
        revert("no eth");
    }
}

contract EsseyCasesDegenTest is Test {
    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant ENTROPY_FEE = 0.001 ether;

    Seat seat;
    Bell bell;
    EsseyCasesDegen degen;
    MockEntropy oracle;
    ERC20Mock usdg;
    ERC20Mock stock; // $200/share
    ERC20Mock essey;
    MockFeed stockFeed;

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256[] fees = [100e18, 250e18, 500e18, 1500e18];
    uint256[] weights = [100, 160, 200, 333];

    // Ladder: 0.65x / 1x / 2x / 5x / 50x at 84% / 10.5% / 4% / 1.3% / 0.2%.
    uint256[] mult = [uint256(6500), 10000, 20000, 50000, 500000];
    uint256[] cum = [uint256(840000), 945000, 985000, 998000, 1000000];

    function setUp() public {
        vm.warp(MON_IN_SESSION);
        usdg = new ERC20Mock();
        stock = new ERC20Mock();
        essey = new ERC20Mock();
        stockFeed = new MockFeed(200e8, 8); // $200
        oracle = new MockEntropy(ENTROPY_FEE);

        seat = new Seat("Essey Seat", "SEAT", 4444, address(this));
        bell = new Bell(seat, essey, usdg, treasury, 100e18, 100, fees, weights, IConverter(address(0)), address(0));

        degen = new EsseyCasesDegen(_cfg());

        stock.mint(address(this), 100_000e18);
        stock.approve(address(degen), type(uint256).max);
        degen.seedReserve(100_000e18);

        essey.mint(alice, 10_000e18);
        usdg.mint(alice, 10_000e18);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        essey.approve(address(degen), type(uint256).max);
        usdg.approve(address(degen), type(uint256).max);
        vm.stopPrank();
    }

    function _cfg() internal view returns (EsseyCasesDegen.Config memory) {
        return EsseyCasesDegen.Config({
            essey: essey,
            bell: bell,
            stockFeed: AggregatorV3Interface(address(stockFeed)),
            sequencerFeed: AggregatorV3Interface(address(0)),
            treasury: treasury,
            bankroll: address(this),
            entropy: IEntropy(address(oracle)),
            entropyProvider: address(0xDACE),
            payoutStock: stock,
            referenceUsd: 100e18,
            casePrice: 100e18,
            buyFee: 5e18,
            boosterShareBps: 7000,
            callbackGasLimit: 100_000,
            multiplierBps: mult,
            cumPpm: cum
        });
    }

    function _buy() internal returns (uint64 seq) {
        vm.prank(alice);
        seq = degen.buy{value: ENTROPY_FEE}();
    }

    function _aliceWithdraw() internal returns (uint256 got) {
        vm.prank(alice);
        got = degen.withdraw();
    }

    // worst case: 100 USD ref x 50 = $5000 -> 25 shares @ $200. That is the reservation.
    function test_BuyReservesWorstCase() public {
        uint256 seq = _buy();
        assertEq(seq, 1);
        assertEq(degen.reservedShares(), 25e18, "worst-case 50x reservation = 25 shares");
        assertEq(essey.balanceOf(treasury), 100e18, "case price sunk to treasury");
        assertEq(usdg.balanceOf(address(bell)), 3.5e18, "70% of fee to the Bell pot");
        assertEq(usdg.balanceOf(treasury), 1.5e18, "30% of fee to treasury");
    }

    function test_SettleFloorThenWithdraw() public {
        uint64 seq = _buy();
        oracle.fulfill(seq, bytes32(uint256(0))); // roll 0 -> 0.65x
        assertEq(degen.owed(alice), 0.325e18, "floor credited (pull-based)");
        assertEq(degen.reservedShares(), 0, "reservation released");
        assertEq(stock.balanceOf(alice), 0, "not paid until withdraw");
        assertEq(_aliceWithdraw(), 0.325e18);
        assertEq(stock.balanceOf(alice), 0.325e18, "withdrawn");
        assertEq(degen.totalOwed(), 0);
    }

    function test_SettleJackpot() public {
        uint64 seq = _buy();
        oracle.fulfill(seq, bytes32(uint256(999_999))); // 50x
        assertEq(degen.owed(alice), 25e18, "jackpot = full reservation");
        assertEq(_aliceWithdraw(), 25e18);
    }

    function test_LadderBandsAccumulateOwed() public {
        oracle.fulfill(_buy(), bytes32(uint256(900_000))); // 1x -> 0.5
        oracle.fulfill(_buy(), bytes32(uint256(970_000))); // 2x -> 1.0
        oracle.fulfill(_buy(), bytes32(uint256(990_000))); // 5x -> 2.5
        assertEq(degen.owed(alice), 0.5e18 + 1e18 + 2.5e18, "owed accumulates across rolls");
        assertEq(_aliceWithdraw(), 4e18);
    }

    /// The real dispatch path: only the oracle may reach settlement via the underscored external.
    function test_EntropyCallbackGatedToOracle() public {
        uint64 seq = _buy();
        vm.prank(bob);
        vm.expectRevert(IEntropyConsumer.NotEntropy.selector);
        degen._entropyCallback(seq, address(0), bytes32(uint256(1)));
        // the oracle itself succeeds
        vm.prank(address(oracle));
        degen._entropyCallback(seq, address(0), bytes32(uint256(0)));
        assertEq(degen.owed(alice), 0.325e18);
    }

    function test_DoubleSettleGuard() public {
        uint64 seq = _buy();
        oracle.fulfill(seq, bytes32(uint256(0)));
        vm.expectRevert(EsseyCasesDegen.AlreadySettled.selector);
        oracle.fulfill(seq, bytes32(uint256(999_999)));
    }

    function test_OffSessionBuyReverts() public {
        vm.warp(MON_IN_SESSION + 8 hours);
        vm.prank(alice);
        vm.expectRevert(EsseyCasesDegen.NotInSession.selector);
        degen.buy{value: ENTROPY_FEE}();
    }

    function test_InsufficientFeeReverts() public {
        vm.prank(alice);
        vm.expectRevert(EsseyCasesDegen.InsufficientFee.selector);
        degen.buy{value: ENTROPY_FEE - 1}();
    }

    function test_FeeRefund() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        degen.buy{value: 0.01 ether}();
        assertEq(alice.balance, before - ENTROPY_FEE, "excess ETH refunded");
    }

    function test_RefundToRejectingBuyerReverts() public {
        RejectsEth r = new RejectsEth();
        essey.mint(address(r), 1_000e18);
        usdg.mint(address(r), 1_000e18);
        vm.deal(address(r), 1 ether);
        // r has no way to approve, so the essey pull fails first; fund + approve via low-level not worth
        // it — instead prove the refund branch: give r exactly the fee so refund==0 succeeds is trivial.
        // Here overpay so the refund call to r reverts.
        vm.prank(address(r));
        essey.approve(address(degen), type(uint256).max);
        vm.prank(address(r));
        usdg.approve(address(degen), type(uint256).max);
        vm.prank(address(r));
        vm.expectRevert(EsseyCasesDegen.RefundFailed.selector);
        r.buyOn{value: 0.01 ether}(degen); // overpay -> refund to r -> r rejects -> RefundFailed
    }

    function test_PermissionlessReclaimAfterTimeout() public {
        uint64 seq = _buy();
        vm.expectRevert(EsseyCasesDegen.NotYetReclaimable.selector);
        degen.reclaim(seq); // before timeout

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(bob); // ANYONE may reclaim; payout still credited to the buyer
        degen.reclaim(seq);
        assertEq(degen.owed(alice), 0.325e18, "floor credited to the buyer, not the caller");
        assertEq(degen.reservedShares(), 0, "reserve un-stuck");
    }

    function test_WithdrawNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(EsseyCasesDegen.NothingOwed.selector);
        degen.withdraw();
    }

    function test_InsufficientBankroll() public {
        EsseyCasesDegen thin = new EsseyCasesDegen(_cfg());
        stock.mint(address(this), 10e18);
        stock.approve(address(thin), type(uint256).max);
        thin.seedReserve(10e18); // 10 shares; a case needs 25
        vm.startPrank(alice);
        essey.approve(address(thin), type(uint256).max);
        usdg.approve(address(thin), type(uint256).max);
        vm.expectRevert(EsseyCasesDegen.InsufficientBankroll.selector);
        thin.buy{value: ENTROPY_FEE}();
        vm.stopPrank();
    }

    function test_BackingCoversEveryOutstandingCase() public {
        EsseyCasesDegen two = new EsseyCasesDegen(_cfg());
        stock.mint(address(this), 50e18);
        stock.approve(address(two), type(uint256).max);
        two.seedReserve(50e18); // exactly two 25-share reservations
        vm.startPrank(alice);
        essey.approve(address(two), type(uint256).max);
        usdg.approve(address(two), type(uint256).max);
        two.buy{value: ENTROPY_FEE}();
        two.buy{value: ENTROPY_FEE}();
        vm.expectRevert(EsseyCasesDegen.InsufficientBankroll.selector);
        two.buy{value: ENTROPY_FEE}();
        vm.stopPrank();
    }

    function test_SeedReserveGated() public {
        vm.prank(bob);
        vm.expectRevert(EsseyCasesDegen.NotBankroll.selector);
        degen.seedReserve(1e18);
        vm.expectRevert(EsseyCasesDegen.BadConfig.selector);
        degen.seedReserve(0);
    }

    function test_ConstructorRejectsBadLadder() public {
        // cumPpm that doesn't end at PPM -> BadConfig
        EsseyCasesDegen.Config memory bad = _cfg();
        bad.multiplierBps = new uint256[](2);
        bad.multiplierBps[0] = 6500;
        bad.multiplierBps[1] = 500000;
        bad.cumPpm = new uint256[](2);
        bad.cumPpm[0] = 500000;
        bad.cumPpm[1] = 900000; // != PPM
        vm.expectRevert(EsseyCasesDegen.BadConfig.selector);
        new EsseyCasesDegen(bad);

        // non-monotonic cumPpm -> BadConfig
        bad.cumPpm[1] = 400000; // <= cumPpm[0]
        vm.expectRevert(EsseyCasesDegen.BadConfig.selector);
        new EsseyCasesDegen(bad);
    }

    function test_SweepEthToTreasury() public {
        // Force some stray ETH into the contract, then sweep it.
        vm.deal(address(degen), 0.5 ether);
        uint256 before = treasury.balance;
        degen.sweepEth();
        assertEq(treasury.balance, before + 0.5 ether, "stray ETH swept to treasury");
        assertEq(address(degen).balance, 0);
    }
}
