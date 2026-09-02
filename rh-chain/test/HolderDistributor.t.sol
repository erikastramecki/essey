// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {BasketRegistry} from "../src/market/BasketRegistry.sol";
import {HolderDistributor, IBasketRegistry} from "../src/market/HolderDistributor.sol";

/// Stands in for StockConverter: pulls USDG from the distributor and mints the target stock to the
/// recipient at 1:1. Models the two things the real converter enforces that the distributor relies on:
/// an is-supported gate and a session gate that reverts off-hours (fail-closed).
contract MockConverter is IConverter {
    IERC20 public immutable usdg;
    mapping(address => bool) public supported;
    bool public session = true;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function setSupported(address t, bool v) external {
        supported[t] = v;
    }

    function setSession(bool v) external {
        session = v;
    }

    function isSupported(address t) external view returns (bool) {
        return supported[t];
    }

    function convert(uint256 amountIn, address targetToken, address recipient) external returns (uint256 out) {
        require(session, "NotInSession");
        usdg.transferFrom(msg.sender, address(this), amountIn);
        out = amountIn;
        ERC20Mock(targetToken).mint(recipient, out);
    }
}

/// A stock token that reenters the distributor on transfer — proves the reentrancy guard holds.
contract ReentrantStock is ERC20Mock {
    HolderDistributor dist;
    bool armed;
    uint256 e;
    address h;
    address t;
    uint256 a;
    bytes32[] p;

    function arm(HolderDistributor d, uint256 e_, address h_, address t_, uint256 a_, bytes32[] memory p_) external {
        dist = d;
        e = e_;
        h = h_;
        t = t_;
        a = a_;
        p = p_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == address(dist)) {
            armed = false;
            dist.push(e, h, t, a, p); // must be blocked by nonReentrant
        }
    }
}

/// Refuses ETH — used to prove a bond slash to a broken sink fails loudly rather than silently.
contract RevertingSink {
    receive() external payable {
        revert("no");
    }
}

contract HolderDistributorTest is Test {
    ERC20Mock usdg;
    ERC20Mock aapl;
    ERC20Mock nvda;
    MockConverter conv;
    BasketRegistry reg;
    HolderDistributor dist;

    address governor = address(this);
    address keeper = address(0x11111);
    address floorSink = address(0xF100);
    address slashSink = address(0x5145);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address stranger = address(0x57A);

    uint256 constant REG_TIMELOCK = 2 days;
    uint256 constant MIN_EPOCH_INTERVAL = 12 hours;
    uint256 constant CHALLENGE_WINDOW = 6 hours;
    uint256 constant CLAIM_WINDOW = 90 days;
    uint256 constant KEEPER_GRACE = 24 hours;
    uint256 constant MIN_BOND = 1 ether;

    function setUp() public {
        vm.warp(1_000_000);
        usdg = new ERC20Mock();
        aapl = new ERC20Mock();
        nvda = new ERC20Mock();
        conv = new MockConverter(IERC20(address(usdg)));
        conv.setSupported(address(aapl), true);
        conv.setSupported(address(nvda), true);

        reg = new BasketRegistry(IConverter(address(conv)), governor, REG_TIMELOCK);
        _registerStock(address(aapl));
        _registerStock(address(nvda));

        dist = new HolderDistributor(
            IERC20(address(usdg)),
            IConverter(address(conv)),
            IBasketRegistry(address(reg)),
            floorSink,
            slashSink,
            governor,
            keeper,
            MIN_EPOCH_INTERVAL,
            CHALLENGE_WINDOW,
            CLAIM_WINDOW,
            KEEPER_GRACE,
            MIN_BOND
        );

        usdg.mint(address(dist), 1_000_000e6); // the accrued 40-bps pot
        vm.deal(keeper, 10 ether);
        vm.prank(keeper);
        dist.postBond{value: MIN_BOND}();
    }

    // -------------------------------------------------------------- helpers

    function _registerStock(address t) internal {
        reg.proposeStock(t);
        vm.warp(block.timestamp + REG_TIMELOCK);
        reg.commitStock(t);
    }

    // Pure — must NOT call the contract, or evaluating it inside a prank/expectRevert argument would
    // consume the cheatcode on the staticcall. Parity with the contract is checked in its own test.
    function _leaf(uint256 e, address h, address t, uint256 a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(e, h, t, a))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _one(bytes32 s) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = s;
    }

    function _empty() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](0);
    }

    /// keeper buys `amt` USDG worth of `token` into the current epoch.
    function _buy(address token, uint256 amt) internal {
        vm.prank(keeper);
        dist.settleBuy(token, amt);
    }

    /// keeper posts `root` for the current epoch after the cadence gate; returns the epoch it finalized.
    function _post(bytes32 root) internal returns (uint256 epoch) {
        vm.warp(block.timestamp + MIN_EPOCH_INTERVAL);
        vm.prank(keeper);
        epoch = dist.postRoot(root);
    }

    // ============================================================== buy path

    function test_SettleBuy_DeliversStockToContractNotKeeper() public {
        _buy(address(aapl), 100e6);
        assertEq(aapl.balanceOf(address(dist)), 100e6, "stock custodied in the distributor");
        assertEq(aapl.balanceOf(keeper), 0, "keeper never receives the bought stock");
        assertEq(dist.reserved(0, address(aapl)), 100e6, "credited to the buy epoch");
    }

    function test_SettleBuy_RevertsForUnregisteredStock() public {
        ERC20Mock ghost = new ERC20Mock();
        conv.setSupported(address(ghost), true); // converter would route it, but the registry never did
        vm.prank(keeper);
        vm.expectRevert(HolderDistributor.NotRegistered.selector);
        dist.settleBuy(address(ghost), 100e6);
    }

    function test_SettleBuy_FailsClosedOffSession() public {
        conv.setSession(false);
        vm.prank(keeper);
        vm.expectRevert(bytes("NotInSession"));
        dist.settleBuy(address(aapl), 100e6);
    }

    function test_SettleBuy_OnlyKeeperOrBondedFallback() public {
        vm.prank(stranger);
        vm.expectRevert(HolderDistributor.NotKeeperOrFallback.selector);
        dist.settleBuy(address(aapl), 100e6);
    }

    // ============================================================== claim / push

    function test_Claim_PaysHolder_AndDecrementsReserved() public {
        _buy(address(aapl), 100e6);
        bytes32 leaf = _leaf(0, alice, address(aapl), 60e6);
        bytes32 root = _pair(leaf, _leaf(0, bob, address(aapl), 40e6));
        uint256 epoch = _post(root);
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        vm.prank(alice);
        dist.claim(epoch, address(aapl), 60e6, _one(_leaf(0, bob, address(aapl), 40e6)));
        assertEq(aapl.balanceOf(alice), 60e6, "alice paid her leaf");
        assertEq(dist.claimable(epoch, address(aapl)), 40e6, "reserved decremented by the payout");
    }

    /// THE divergence from Floor: push delivers to the leaf's holder, never to the caller.
    function test_Push_PaysLeafHolder_NotCaller() public {
        _buy(address(aapl), 100e6);
        bytes32 leaf = _leaf(0, alice, address(aapl), 100e6);
        uint256 epoch = _post(leaf); // single-leaf tree: root == leaf
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        vm.prank(keeper); // the keeper pushes on alice's behalf
        dist.push(epoch, alice, address(aapl), 100e6, _empty());
        assertEq(aapl.balanceOf(alice), 100e6, "the leaf's holder is paid");
        assertEq(aapl.balanceOf(keeper), 0, "the caller is NOT paid");
    }

    function test_Claim_DoubleClaimReverts() public {
        _buy(address(aapl), 100e6);
        bytes32 leaf = _leaf(0, alice, address(aapl), 100e6);
        uint256 epoch = _post(leaf);
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        vm.prank(alice);
        dist.claim(epoch, address(aapl), 100e6, _empty());
        vm.prank(alice);
        vm.expectRevert(HolderDistributor.AlreadyClaimed.selector);
        dist.claim(epoch, address(aapl), 100e6, _empty());
        assertEq(aapl.balanceOf(alice), 100e6, "paid exactly once");
    }

    /// self-claim then keeper-push of the SAME leaf must not double-pay.
    function test_ClaimThenPush_NoDoublePay() public {
        _buy(address(aapl), 100e6);
        bytes32 leaf = _leaf(0, alice, address(aapl), 100e6);
        uint256 epoch = _post(leaf);
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        vm.prank(alice);
        dist.claim(epoch, address(aapl), 100e6, _empty());
        vm.prank(keeper);
        vm.expectRevert(HolderDistributor.AlreadyClaimed.selector);
        dist.push(epoch, alice, address(aapl), 100e6, _empty());
        assertEq(aapl.balanceOf(alice), 100e6, "still paid exactly once");
    }

    function test_ChallengeWindow_BlocksPrematureClaim() public {
        _buy(address(aapl), 100e6);
        bytes32 leaf = _leaf(0, alice, address(aapl), 100e6);
        uint256 epoch = _post(leaf);

        vm.prank(alice); // still inside the challenge window
        vm.expectRevert(HolderDistributor.ChallengeWindowActive.selector);
        dist.claim(epoch, address(aapl), 100e6, _empty());

        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        vm.prank(alice);
        dist.claim(epoch, address(aapl), 100e6, _empty());
        assertEq(aapl.balanceOf(alice), 100e6, "claimable once the window elapses");
    }

    function test_Leaf_BindsHolderTokenAmountEpoch() public {
        _buy(address(aapl), 100e6);
        bytes32 leaf = _leaf(0, alice, address(aapl), 100e6);
        uint256 epoch = _post(leaf);
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        // bob presenting alice's proof -> leaf differs -> BadProof
        vm.prank(bob);
        vm.expectRevert(HolderDistributor.BadProof.selector);
        dist.claim(epoch, address(aapl), 100e6, _empty());

        // wrong amount -> leaf differs
        vm.prank(alice);
        vm.expectRevert(HolderDistributor.BadProof.selector);
        dist.claim(epoch, address(aapl), 99e6, _empty());

        // wrong token -> leaf differs
        vm.prank(alice);
        vm.expectRevert(HolderDistributor.BadProof.selector);
        dist.claim(epoch, address(nvda), 100e6, _empty());
    }

    // ============================================================== solvency

    function test_Solvency_ClaimCannotExceedReserved() public {
        _buy(address(aapl), 100e6);
        bytes32 leaf = _leaf(0, alice, address(aapl), 101e6); // over-attributed by the root
        uint256 epoch = _post(leaf);
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        vm.prank(alice);
        vm.expectRevert(HolderDistributor.ExceedsReserved.selector);
        dist.claim(epoch, address(aapl), 101e6, _empty());
    }

    /// A bad root in one epoch cannot bleed another epoch's stock — the isolation invariant.
    function test_Solvency_EpochsAreIsolated() public {
        // epoch 0: 100 AAPL bought, but the root over-attributes 100 to EACH of alice and bob (200 total).
        _buy(address(aapl), 100e6);
        bytes32 a0 = _leaf(0, alice, address(aapl), 100e6);
        bytes32 b0 = _leaf(0, bob, address(aapl), 100e6);
        uint256 e0 = _post(_pair(a0, b0));

        // epoch 1: 50 AAPL bought, cleanly attributed 50 to bob.
        _buy(address(aapl), 50e6);
        bytes32 b1 = _leaf(1, bob, address(aapl), 50e6);
        uint256 e1 = _post(b1);

        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        // alice drains all of epoch 0's 100.
        vm.prank(alice);
        dist.claim(e0, address(aapl), 100e6, _one(b0));
        // bob's epoch-0 leaf now over-draws -> blocked; epoch 0 is exhausted.
        vm.prank(bob);
        vm.expectRevert(HolderDistributor.ExceedsReserved.selector);
        dist.claim(e0, address(aapl), 100e6, _one(a0));
        // but bob's epoch-1 claim is untouched by epoch 0's overflow.
        vm.prank(bob);
        dist.claim(e1, address(aapl), 50e6, _empty());
        assertEq(aapl.balanceOf(bob), 50e6, "epoch 1 pays in full despite epoch 0 overflow");
        assertEq(aapl.balanceOf(alice), 100e6, "epoch 0 paid at most what it bought");
    }

    // ============================================================== challenge + slash

    function test_ChallengeRoot_VoidsAndSlashes() public {
        _buy(address(aapl), 100e6);
        bytes32 leaf = _leaf(0, alice, address(aapl), 100e6);
        uint256 epoch = _post(leaf);

        assertEq(dist.bond(keeper), MIN_BOND, "keeper bonded pre-challenge");
        dist.challengeRoot(epoch); // governor, inside the window
        assertEq(dist.bond(keeper), 0, "poster bond slashed to zero");
        assertEq(slashSink.balance, MIN_BOND, "slashed bond routed to the slash sink");
        assertEq(dist.epochRoot(epoch), bytes32(0), "root voided");

        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        vm.prank(alice);
        vm.expectRevert(HolderDistributor.UnknownEpoch.selector);
        dist.claim(epoch, address(aapl), 100e6, _empty());
    }

    function test_ChallengeRoot_RevertsAfterWindow() public {
        _buy(address(aapl), 100e6);
        uint256 epoch = _post(_leaf(0, alice, address(aapl), 100e6));
        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        vm.expectRevert(HolderDistributor.ChallengeWindowActive.selector);
        dist.challengeRoot(epoch);
    }

    function test_ChallengeRoot_OnlyGovernor() public {
        _buy(address(aapl), 100e6);
        uint256 epoch = _post(_leaf(0, alice, address(aapl), 100e6));
        vm.prank(stranger);
        vm.expectRevert(HolderDistributor.NotGovernor.selector);
        dist.challengeRoot(epoch);
    }

    // ============================================================== liveness: bonded fallback

    function test_Fallback_BondedStrangerCanPostAfterGrace() public {
        _buy(address(aapl), 100e6); // keeper bought; then goes dark
        vm.deal(stranger, 10 ether);
        vm.prank(stranger);
        dist.postBond{value: MIN_BOND}();

        // before grace: stranger cannot post
        vm.warp(block.timestamp + MIN_EPOCH_INTERVAL);
        vm.prank(stranger);
        vm.expectRevert(HolderDistributor.NotKeeperOrFallback.selector);
        dist.postRoot(_leaf(0, alice, address(aapl), 100e6));

        // after grace: stranger CAN post
        vm.warp(block.timestamp + KEEPER_GRACE);
        vm.prank(stranger);
        uint256 epoch = dist.postRoot(_leaf(0, alice, address(aapl), 100e6));
        assertEq(dist.rootPoster(epoch), stranger, "fallback poster recorded for slashing");
    }

    function test_Fallback_UnbondedStrangerCannotPost() public {
        _buy(address(aapl), 100e6);
        vm.warp(block.timestamp + KEEPER_GRACE + MIN_EPOCH_INTERVAL);
        vm.prank(stranger); // past grace but no bond
        vm.expectRevert(HolderDistributor.InsufficientBond.selector);
        dist.postRoot(_leaf(0, alice, address(aapl), 100e6));
    }

    // ============================================================== cadence + bond lock

    function test_Cadence_PostRootTooEarlyReverts() public {
        _buy(address(aapl), 100e6);
        _post(_leaf(0, alice, address(aapl), 100e6)); // epoch 0 at t
        _buy(address(aapl), 100e6);
        vm.prank(keeper); // immediately, without waiting the interval
        vm.expectRevert(HolderDistributor.TooEarly.selector);
        dist.postRoot(_leaf(1, alice, address(aapl), 100e6));
    }

    function test_Bond_CannotWithdrawWhileRootInChallengeWindow() public {
        _buy(address(aapl), 100e6);
        _post(_leaf(0, alice, address(aapl), 100e6));
        vm.prank(keeper);
        vm.expectRevert(HolderDistributor.BondLocked.selector);
        dist.withdrawBond(MIN_BOND);

        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        vm.prank(keeper);
        dist.withdrawBond(MIN_BOND);
        assertEq(dist.bond(keeper), 0, "bond withdrawable once the window closes");
    }

    // ============================================================== claim window + sweep

    function test_ClaimWindow_ClosesThenSweepToFloor() public {
        _buy(address(aapl), 100e6);
        uint256 epoch = _post(_leaf(0, alice, address(aapl), 100e6));
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        // sweep not yet allowed
        vm.expectRevert(HolderDistributor.NotYetSweepable.selector);
        dist.sweepEpoch(epoch, address(aapl));

        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(HolderDistributor.ClaimWindowClosed.selector);
        dist.claim(epoch, address(aapl), 100e6, _empty());

        dist.sweepEpoch(epoch, address(aapl));
        assertEq(aapl.balanceOf(floorSink), 100e6, "unclaimed stock swept to the floor");
        assertEq(dist.claimable(epoch, address(aapl)), 0, "nothing left to claim after sweep");
    }

    function test_Sweep_AfterChallengeGoesToFloor() public {
        _buy(address(aapl), 100e6);
        uint256 epoch = _post(_leaf(0, alice, address(aapl), 100e6));
        dist.challengeRoot(epoch); // voided -> immediately sweepable
        dist.sweepEpoch(epoch, address(aapl));
        assertEq(aapl.balanceOf(floorSink), 100e6, "voided-epoch stock returns to the floor");
    }

    // ============================================================== reentrancy

    function test_Reentrancy_TransferCallbackBlocked() public {
        ReentrantStock rs = new ReentrantStock();
        conv.setSupported(address(rs), true);
        _registerStock(address(rs));

        vm.prank(keeper);
        dist.settleBuy(address(rs), 100e6);
        bytes32 leaf = _leaf(0, alice, address(rs), 100e6);
        uint256 epoch = _post(leaf);
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        rs.arm(dist, epoch, alice, address(rs), 100e6, _empty());
        vm.prank(alice);
        vm.expectRevert(); // ReentrancyGuardReentrantCall
        dist.claim(epoch, address(rs), 100e6, _empty());
    }

    // ============================================================== registry: append-only + timelock

    function test_Registry_CommitBeforeTimelockReverts() public {
        ERC20Mock t = new ERC20Mock();
        conv.setSupported(address(t), true);
        reg.proposeStock(address(t));
        vm.expectRevert(BasketRegistry.TimelockNotElapsed.selector);
        reg.commitStock(address(t));
    }

    function test_Registry_ProposeUnsupportedReverts() public {
        ERC20Mock t = new ERC20Mock(); // converter does NOT support it
        vm.expectRevert(BasketRegistry.NotSupported.selector);
        reg.proposeStock(address(t));
    }

    function test_Registry_OnlyGovernorCanPropose() public {
        vm.prank(stranger);
        vm.expectRevert(BasketRegistry.NotGovernor.selector);
        reg.proposeStock(address(aapl));
    }

    function test_Registry_StockIsAppendOnly() public view {
        assertTrue(reg.isRegisteredStock(address(aapl)), "aapl registered");
        assertTrue(reg.isRegisteredStock(address(nvda)), "nvda registered");
        assertEq(reg.stockCount(), 2, "exactly the two committed stocks");
        // BasketRegistry exposes NO removal/mutation function — append-only by construction.
    }

    function test_Registry_BasketWeightsMustSumToBps() public {
        address[] memory tks = new address[](2);
        tks[0] = address(aapl);
        tks[1] = address(nvda);
        uint16[] memory bps = new uint16[](2);
        bps[0] = 6000;
        bps[1] = 3999; // sums to 9999, not 10000
        vm.expectRevert(BasketRegistry.BadWeights.selector);
        reg.proposeBasket("Tech", tks, bps);
    }

    function test_Registry_BasketMemberMustBeRegistered() public {
        ERC20Mock ghost = new ERC20Mock();
        address[] memory tks = new address[](1);
        tks[0] = address(ghost);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10000;
        vm.expectRevert(BasketRegistry.NotSupported.selector);
        reg.proposeBasket("Ghost", tks, bps);
    }

    function test_Registry_BasketCommitTimelocked() public {
        address[] memory tks = new address[](2);
        tks[0] = address(aapl);
        tks[1] = address(nvda);
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5000;
        bps[1] = 5000;
        uint256 id = reg.proposeBasket("Even", tks, bps);
        vm.expectRevert(BasketRegistry.TimelockNotElapsed.selector);
        reg.commitBasket(id);

        vm.warp(block.timestamp + REG_TIMELOCK);
        reg.commitBasket(id);
        assertTrue(reg.isCommittedBasket(id), "basket live after timelock");
        (, address[] memory got,,) = reg.basketOf(id);
        assertEq(got.length, 2, "basket constituents stored");
    }

    // ============================================================== governor: keeper rotation

    function test_Governor_RotatesKeeper() public {
        // keeper posts so the fallback window is freshly closed, isolating the rotation effect.
        _buy(address(aapl), 100e6);
        _post(_leaf(0, alice, address(aapl), 100e6));
        address k2 = address(0xC0FFEE);
        dist.setKeeper(k2);
        assertEq(dist.keeper(), k2, "keeper rotated");
        vm.prank(keeper); // old keeper, within grace, is no longer authorized
        vm.expectRevert(HolderDistributor.NotKeeperOrFallback.selector);
        dist.settleBuy(address(aapl), 100e6);
    }

    function test_Governor_OnlyGovernorSetsKeeper() public {
        vm.prank(stranger);
        vm.expectRevert(HolderDistributor.NotGovernor.selector);
        dist.setKeeper(stranger);
    }

    // ============================================================== leaf parity

    function test_LeafOf_MatchesLocalHash() public view {
        assertEq(dist.leafOf(3, alice, address(aapl), 42e6), _leaf(3, alice, address(aapl), 42e6), "leaf parity");
    }
}
