// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GameLedger} from "../src/game/GameLedger.sol";
import {IGameController} from "../src/game/GameTypes.sol";
import {BurnableStock, MockController} from "./GameLedger.t.sol";

/// Drives every value primitive with bounded-but-arbitrary amounts against a real 6-dec token, so the
/// solvency law is pinned across long random op sequences, not just hand-picked cases.
contract LedgerHandler is Test {
    GameLedger public ledger;
    BurnableStock public token;
    address public payer = address(0xF00D);

    uint256 internal constant INDEX_ONE = 1e18;

    /// Latched once fund() or debit() ever injects unattributed surplus. While false, the pool's real
    /// balance is fully owned (bar rounding dust), which is the exact state that pins the M9 reconciler.
    bool public surplusTainted;
    /// Burns that reconciled while the index was ALREADY sub-ONE — the compounding regime where the
    /// M9 `*idx` mutant diverges from the correct `*ONE` form. Proves the fuzz reaches ragged compounding.
    uint256 public compoundingReconciles;

    address[2] public single = [address(0xA1), address(0xA2)];
    address[3] public contested = [address(0xB1), address(0xB2), address(0xB3)];

    constructor(GameLedger ledger_, BurnableStock token_) {
        ledger = ledger_;
        token = token_;
    }

    function _fundPayer(uint256 amt) internal {
        token.mint(payer, amt);
        vm.prank(payer);
        token.approve(address(ledger), amt);
    }

    function deposit(uint256 accSeed, uint256 amt) external {
        amt = bound(amt, 1, 1e12);
        address acc = _anyAccount(accSeed);
        _fundPayer(amt);
        try ledger.deposit(address(token), payer, acc, amt) {} catch {}
    }

    function fund(uint256 amt) external {
        amt = bound(amt, 1, 1e12);
        _fundPayer(amt);
        try ledger.fund(address(token), payer, amt) {
            surplusTainted = true;
        } catch {}
    }

    function credit(uint256 accSeed, uint256 amt) external {
        amt = bound(amt, 1, 1e12);
        try ledger.credit(address(token), _anyAccount(accSeed), amt) {} catch {}
    }

    function debit(uint256 accSeed, uint256 amt) external {
        amt = bound(amt, 1, 1e12);
        try ledger.debit(address(token), _anyAccount(accSeed), amt) {
            surplusTainted = true;
        } catch {}
    }

    function withdraw(uint256 accSeed, uint256 amt) external {
        amt = bound(amt, 1, 1e12);
        try ledger.withdraw(address(token), _anyAccount(accSeed), address(0xDEAD), amt) {} catch {}
    }

    function collectFee(uint256 accSeed, uint256 amt) external {
        amt = bound(amt, 1, 1e12);
        try ledger.collectFee(address(token), _anyAccount(accSeed), amt) {} catch {}
    }

    function move(uint256 aSeed, uint256 bSeed, uint256 amt) external {
        amt = bound(amt, 1, 1e12);
        try ledger.move(address(token), _contested(aSeed), _contested(bSeed), amt) {} catch {}
    }

    /// The issuer's adminBurn on the custodian's balance — the whole reason the survival index exists.
    /// Burns a bounded, deliberately NON-DIVISOR slice and reconciles, so `solvencyIndex` leaves ONE and
    /// the ragged regime (floor-in / ceil-out rounding, pro-rata haircut) is actually driven under fuzz.
    /// Self-syncs: isSolvent reads the stored index and does not reconcile, so the pinned view would be
    /// transiently false between a raw burn and the next value op.
    function burn(uint256 seed, uint256 bps) external {
        uint256 bal = token.balanceOf(address(ledger));
        if (bal < 1_000) return; // keep the pool large enough that the ragged index never hits terminal
        bps = bound(bps, 1, 5_000); // at most half per burn, so the index ratchets gradually, not to 0
        uint256 amt = (bal * bps) / 10_000;
        amt += 1 + (seed % 7); // nudge off clean divisors so the index goes ragged, not round
        if (amt >= bal) amt = bal / 2; // never approach a total burn
        if (amt == 0) return;
        uint256 preIdx = ledger.solvencyIndex(address(token));
        token.adminBurn(address(ledger), amt);
        ledger.sync(address(token));
        // a reconcile that moved the index while it was ALREADY sub-ONE is a compounding burn — the
        // only regime where M9's `*idx` form diverges from the correct `*ONE` form.
        if (preIdx < INDEX_ONE && ledger.solvencyIndex(address(token)) < preIdx) compoundingReconciles += 1;
    }

    /// Standalone reconcile poke, interleaved by the fuzzer independently of the value ops.
    function sync() external {
        try ledger.sync(address(token)) {} catch {}
    }

    function cross(uint256 sSeed, uint256 cSeed, bool outward, uint256 amt) external {
        amt = bound(amt, 1, 1e12);
        address s = _single(sSeed);
        address c = _contested(cSeed);
        (address from, address to) = outward ? (s, c) : (c, s);
        try ledger.cross(address(token), from, to, amt) {} catch {}
    }

    function _anyAccount(uint256 seed) internal view returns (address) {
        uint256 i = seed % 5;
        return i < 2 ? single[i] : contested[i - 2];
    }

    function _single(uint256 seed) internal view returns (address) {
        return single[seed % 2];
    }

    function _contested(uint256 seed) internal view returns (address) {
        return contested[seed % 3];
    }
}

contract GameLedgerInvariantTest is Test {
    GameLedger ledger;
    MockController controller;
    BurnableStock token;
    LedgerHandler handler;

    address admin = address(0xA11CE);
    uint256 constant INDEX_ONE = 1e18; // mirrors GameLedger.INDEX_ONE (internal), for the ragged guard

    /// Upper bound on real tokens legitimately unowned in an untainted pool. Every source is per-op
    /// double-floor/ceil dust (< ~2 units), and each burn reconcile collapses accumulated surplus back
    /// to ~0, so a 500-deep run cannot approach this. The M9 mutant strands a FRACTION of the pool here
    /// (1e11+ at fuzz scale) — six-plus orders of magnitude clear of this bound.
    uint256 constant STRAND_DUST = 100_000;

    function setUp() public {
        controller = new MockController(admin);
        vm.prank(admin);
        ledger = new GameLedger(IGameController(address(controller)), address(0xFEE5));
        token = new BurnableStock(6); // exercise the 6-dec footgun under fuzzing

        vm.prank(admin);
        ledger.addToken(address(token));

        handler = new LedgerHandler(ledger, token);
        controller.setModule(address(handler), true);

        // the handler registers its account taxonomy through the module gate
        vm.startPrank(address(handler));
        ledger.registerAccount(address(0xA1), GameLedger.Domain.SINGLE_PARTY);
        ledger.registerAccount(address(0xA2), GameLedger.Domain.SINGLE_PARTY);
        ledger.registerAccount(address(0xB1), GameLedger.Domain.CONTESTED);
        ledger.registerAccount(address(0xB2), GameLedger.Domain.CONTESTED);
        ledger.registerAccount(address(0xB3), GameLedger.Domain.CONTESTED);
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// THE pinned solvency law: the custodian's real balance always covers every effective ledger.
    function invariant_solvency() public view {
        assertTrue(ledger.isSolvent(address(token)));
    }

    /// No value appears from nothing. Under a ragged index each part floors independently, so
    /// Σ⌊scaledᵢ·idx⌋ ≤ ⌊Σscaled·idx⌋ — the total dominates the parts, never the reverse (an
    /// over-credit / mint-vector mutant inverts this). Exact equality is re-pinned in the unburned
    /// (index==ONE) regime where floor is a no-op.
    function invariant_totalMatchesParts() public view {
        address[5] memory accs = [address(0xA1), address(0xA2), address(0xB1), address(0xB2), address(0xB3)];
        uint256 sum;
        for (uint256 i; i < accs.length; i++) {
            sum += ledger.effectiveBalanceOf(address(token), accs[i]);
        }
        uint256 total = ledger.effectiveTotalOf(address(token));
        assertGe(total, sum);
        if (ledger.solvencyIndex(address(token)) == INDEX_ONE) {
            assertEq(sum, total);
        }
        assertGe(token.balanceOf(address(ledger)), sum);
    }

    /// M9 COMPOUNDING PIN: with no fund/debit surplus ever injected, every real token in the pool is
    /// owned, so the reconciler must keep effTotal flush with the real backing even after sub-ONE burns
    /// compound (the exact case `invariant_totalMatchesParts`'s `>=` and idx==ONE `==` both miss). The
    /// `*idx` mutant strands a large fraction of the pool as un-owned surplus here — far past STRAND_DUST.
    function invariant_noBurnStrandsValue() public view {
        if (handler.surplusTainted()) return;
        uint256 bal = token.balanceOf(address(ledger));
        uint256 total = ledger.effectiveTotalOf(address(token));
        assertLe(bal - total, STRAND_DUST); // bal >= total by invariant_solvency; excess is dust, not stranding
    }

    /// Non-degeneracy, deterministic: drive the SAME handler the fuzz uses through an untainted
    /// two-burn (compounding) sequence and prove (a) the compounding counter actually increments, so
    /// `invariant_noBurnStrandsValue` is reachable in-regime rather than trivially skipped, and (b) the
    /// pin holds there — the strong equality the `*idx` mutant breaks. (Foundry reverts handler state to
    /// the setUp snapshot between fuzz runs, so this counter can't be asserted campaign-wide in
    /// afterInvariant; a direct drive is the durable check.)
    function test_handler_reachesUntaintedCompounding_andPins() public {
        handler.deposit(2, 1e12); // seed a contested account (accSeed 2 -> contested[0]), max in-range amount
        handler.burn(0, 4_000); // first reconcile lands at idx < ONE
        handler.burn(0, 4_000); // second reconcile compounds off the sub-ONE index
        assertGt(handler.compoundingReconciles(), 0);
        assertFalse(handler.surplusTainted()); // no fund/debit ran -> the strong pin is live
        invariant_noBurnStrandsValue(); // must hold on the pristine contract; RED under the *idx mutant
    }
}
