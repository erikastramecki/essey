// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../src/market/EsseyLadderSeeder.sol";

/// Anchors the vendored TickMath against the two published canonical values (tick 0 = Q96 exactly;
/// MAX_TICK = canonical MAX_SQRT_RATIO, which exercises every magic constant), plus monotonicity
/// across the ladder's own ticks. The fork rehearsal then proves bit-equality against the REAL
/// deployed pool bytecode (slot0 tick assertion in SeedEsseyLadder._verifyAndReport).
contract EsseyLadderTickMathTest is Test {
    function test_canonicalAnchors() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(0), uint160(79228162514264337593543950336)); // 2^96
        assertEq(
            uint256(TickMath.getSqrtRatioAtTick(887272)),
            1461446703485210103287273052203988822378723970342 // canonical MAX_SQRT_RATIO
        );
        assertEq(uint256(TickMath.getSqrtRatioAtTick(-887272)), 4295128739); // canonical MIN_SQRT_RATIO
    }

    function test_ladderTicksMonotonic() public pure {
        int24[8] memory ticks =
            [int24(-381120), -370140, -358080, -342000, int24(342000), 358080, 370140, 381120];
        uint160 prev;
        for (uint256 i = 0; i < 8; i++) {
            uint160 s = TickMath.getSqrtRatioAtTick(ticks[i]);
            assertGt(uint256(s), uint256(prev));
            prev = s;
        }
    }
}
