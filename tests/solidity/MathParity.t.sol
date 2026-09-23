// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "./reference/FullMath.sol";
import {BitMath} from "./reference/BitMath.sol";
import {TickMath} from "./reference/TickMath.sol";

import {SqrtPriceMath} from "./reference/SqrtPriceMath.sol";
import {SwapMath} from "./reference/SwapMath.sol";
import {UnsafeMath} from "./reference/UnsafeMath.sol";
import {SafeCast} from "./reference/SafeCast.sol";

interface Vm {
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
}

contract SolidityMathHarness {
    function nextPrice(uint160 price, uint128 liquidity, uint256 amount, bool direction, uint8 mode) external pure returns (uint160) {
        if (mode == 0) return SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(price, liquidity, amount, direction);
        if (mode == 1) return SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(price, liquidity, amount, direction);
        if (mode == 2) return SqrtPriceMath.getNextSqrtPriceFromInput(price, liquidity, amount, direction);
        return SqrtPriceMath.getNextSqrtPriceFromOutput(price, liquidity, amount, direction);
    }
    function amountDelta(uint160 a, uint160 b, uint128 liquidity, bool roundUp, bool token0) external pure returns (uint256) {
        return token0 ? SqrtPriceMath.getAmount0Delta(a, b, liquidity, roundUp) : SqrtPriceMath.getAmount1Delta(a, b, liquidity, roundUp);
    }
    function signedDelta(uint160 a, uint160 b, int128 liquidity, bool token0) external pure returns (int256) {
        return token0 ? SqrtPriceMath.getAmount0Delta(a, b, liquidity) : SqrtPriceMath.getAmount1Delta(a, b, liquidity);
    }
    function swapStep(uint160 current, uint160 target, uint128 liquidity, int256 remaining, uint24 fee) external pure returns (uint160, uint256, uint256, uint256) {
        return SwapMath.computeSwapStep(current, target, liquidity, remaining, fee);
    }
    function priceTarget(bool direction, uint160 next, uint160 limit) external pure returns (uint160) {
        return SwapMath.getSqrtPriceTarget(direction, next, limit);
    }
    function unsafeMath(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256, uint256) {
        return (UnsafeMath.divRoundingUp(a, denominator), UnsafeMath.simpleMulDiv(a, b, denominator));
    }
    function safeCast(uint256 unsignedValue, int256 signedValue, uint8 mode) external pure returns (uint256) {
        if (mode == 0) return SafeCast.toUint160(unsignedValue);
        if (mode == 1) return SafeCast.toUint128(unsignedValue);
        if (mode == 2) return uint256(SafeCast.toInt256(unsignedValue));
        if (mode == 3) return uint256(int256(SafeCast.toInt128(signedValue)));
        if (mode == 4) return uint256(int256(SafeCast.toInt128(unsignedValue)));
        return SafeCast.toUint128(int128(signedValue));
    }

    function sqrtPriceAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
    function tickAtSqrtPrice(uint160 price) external pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(price);
    }
    function usableTicks(int24 spacing) external pure returns (int24, int24) {
        return (TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing));
    }
    function mulDiv(uint256 a, uint256 b, uint256 denominator, bool roundUp) external pure returns (uint256) {
        return roundUp ? FullMath.mulDivRoundingUp(a, b, denominator) : FullMath.mulDiv(a, b, denominator);
    }
    function bits(uint256 value) external pure returns (uint8, uint8) {
        return (BitMath.mostSignificantBit(value), BitMath.leastSignificantBit(value));
    }
}

contract MathParityTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityMathHarness referenceMath;

    function setUp() public {
        bytes memory initcode = vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        address deployed;
        assembly { deployed := create(0, add(initcode, 32), mload(initcode)) }
        require(deployed.code.length != 0, "Fe deployment failed");
        fe = deployed;
        referenceMath = new SolidityMathHarness();
    }

    function compare(bytes memory data) internal view returns (bytes memory result) {
        (bool feOk, bytes memory feResult) = fe.staticcall(data);
        (bool solOk, bytes memory solResult) = address(referenceMath).staticcall(data);
        require(feOk == solOk, "success/revert mismatch");
        require(keccak256(feResult) == keccak256(solResult), "return/revert payload mismatch");
        return feResult;
    }

    function testFuzz_tickAllInputs(int24 tick) public view {
        compare(abi.encodeCall(referenceMath.sqrtPriceAtTick, (tick)));
    }

    function testFuzz_validTickAndAdjacentPrices(int24 seed) public view {
        int24 tick = seed % 887272;
        uint160 price = abi.decode(compare(abi.encodeCall(referenceMath.sqrtPriceAtTick, (tick))), (uint160));
        int24 recovered = abi.decode(compare(abi.encodeCall(referenceMath.tickAtSqrtPrice, (price))), (int24));
        require(recovered == tick, "roundtrip");
        compare(abi.encodeCall(referenceMath.tickAtSqrtPrice, (price - 1)));
        compare(abi.encodeCall(referenceMath.tickAtSqrtPrice, (price + 1)));
    }

    function testFuzz_priceAllInputs(uint160 price) public view {
        compare(abi.encodeCall(referenceMath.tickAtSqrtPrice, (price)));
    }

    function testFuzz_spacingAllInputs(int24 spacing) public view {
        compare(abi.encodeCall(referenceMath.usableTicks, (spacing)));
    }

    function testFuzz_mulDiv(uint256 a, uint256 b, uint256 d, bool roundUp) public view {
        compare(abi.encodeCall(referenceMath.mulDiv, (a, b, d, roundUp)));
    }

    function testFuzz_bits(uint256 value) public view {
        compare(abi.encodeCall(referenceMath.bits, (value)));
    }

    function testFuzz_nextPrice(uint160 price, uint128 liquidity, uint256 amount, bool direction, uint8 mode) public view {
        compare(abi.encodeCall(referenceMath.nextPrice, (price, liquidity, amount, direction, mode % 4)));
    }
    function testFuzz_amountDelta(uint160 a, uint160 b, uint128 liquidity, bool roundUp, bool token0) public view {
        compare(abi.encodeCall(referenceMath.amountDelta, (a, b, liquidity, roundUp, token0)));
    }
    function testFuzz_signedDelta(uint160 a, uint160 b, int128 liquidity, bool token0) public view {
        compare(abi.encodeCall(referenceMath.signedDelta, (a, b, liquidity, token0)));
    }
    function testFuzz_swapStep(uint160 current, uint160 target, uint128 liquidity, int256 remaining, uint24 fee) public view {
        compare(abi.encodeCall(referenceMath.swapStep, (current, target, liquidity, remaining, fee % 1000001)));
    }
    function testFuzz_priceTarget(bool direction, uint160 next, uint160 limit) public view {
        compare(abi.encodeCall(referenceMath.priceTarget, (direction, next, limit)));
    }
    function testFuzz_unsafeMath(uint256 a, uint256 b, uint256 denominator) public view {
        compare(abi.encodeCall(referenceMath.unsafeMath, (a, b, denominator)));
    }
    function testFuzz_safeCast(uint256 unsignedValue, int256 signedValue, uint8 mode) public view {
        compare(abi.encodeCall(referenceMath.safeCast, (unsignedValue, signedValue, mode % 6)));
    }
    function testFuzz_successfulSwapInvariants(int16 tickA, int16 tickB, uint64 liquiditySeed, uint64 amountSeed, uint24 feeSeed, bool exactInput) public view {
        uint160 current = referenceMath.sqrtPriceAtTick(tickA);
        uint160 target = referenceMath.sqrtPriceAtTick(tickB);
        uint128 liquidity = uint128(liquiditySeed) + 1;
        int256 magnitude = int256(uint256(amountSeed)) + 1;
        int256 remaining = exactInput ? -magnitude : magnitude;
        uint24 fee = feeSeed % 1000000;
        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 feeAmount) = abi.decode(
            compare(abi.encodeCall(referenceMath.swapStep, (current, target, liquidity, remaining, fee))),
            (uint160, uint256, uint256, uint256)
        );
        require(next >= (current < target ? current : target), "price below range");
        require(next <= (current > target ? current : target), "price above range");
        if (exactInput) require(amountIn + feeAmount <= uint256(magnitude), "input budget exceeded");
        else require(amountOut <= uint256(magnitude), "excess output");
    }

    function test_swapAndPriceBoundaries() public view {
        uint160[5] memory prices = [uint160(0), 1, 1 << 96, TickMath.MAX_SQRT_PRICE - 1, type(uint160).max];
        uint128[4] memory liquidities = [uint128(0), 1, 1 << 127, type(uint128).max];
        uint256[6] memory amounts = [uint256(0), 1, 1 << 96, type(uint160).max, uint256(1) << 160, type(uint256).max];
        for (uint256 p; p < prices.length; ++p) {
            for (uint256 l; l < liquidities.length; ++l) {
                for (uint256 a; a < amounts.length; ++a) {
                    for (uint8 mode; mode < 4; ++mode) {
                        compare(abi.encodeCall(referenceMath.nextPrice, (prices[p], liquidities[l], amounts[a], true, mode)));
                        compare(abi.encodeCall(referenceMath.nextPrice, (prices[p], liquidities[l], amounts[a], false, mode)));
                    }
                }
            }
        }
        int256[5] memory remaining = [type(int256).min, int256(-1), int256(0), int256(1), type(int256).max];
        uint24[4] memory fees = [uint24(0), 3000, 999999, 1000000];
        for (uint256 r; r < remaining.length; ++r) {
            for (uint256 f; f < fees.length; ++f) {
                compare(abi.encodeCall(referenceMath.swapStep, (uint160(1 << 96), uint160(2 << 96), uint128(1000000), remaining[r], fees[f])));
                compare(abi.encodeCall(referenceMath.swapStep, (uint160(2 << 96), uint160(1 << 96), uint128(1000000), remaining[r], fees[f])));
                compare(abi.encodeCall(referenceMath.swapStep, (uint160(1 << 96), uint160(1 << 96), uint128(0), remaining[r], fees[f])));
            }
        }
        for (uint256 l; l < liquidities.length; ++l) {
            for (uint256 p; p < prices.length; ++p) {
                compare(abi.encodeCall(referenceMath.signedDelta, (prices[p], uint160(1 << 96), int128(liquidities[l]), true)));
                compare(abi.encodeCall(referenceMath.signedDelta, (prices[p], uint160(1 << 96), int128(liquidities[l]), false)));
            }
        }
        compare(abi.encodeCall(referenceMath.unsafeMath, (type(uint256).max, type(uint256).max, uint256(0))));
        for (uint256 bit; bit < 256; ++bit) {
            for (uint8 mode; mode < 6; ++mode) {
                compare(abi.encodeCall(referenceMath.safeCast, ((uint256(1) << bit) - 1, int256((uint256(1) << bit) - 1), mode)));
                compare(abi.encodeCall(referenceMath.safeCast, (uint256(1) << bit, int256(uint256(1) << bit), mode)));
            }
        }
    }

    function test_boundaries() public view {
        int24[13] memory ticks = [int24(-8388608), -887273, -887272, -887271, -1, 0, 1, 887270, 887271, 887272, 887273, 8388606, 8388607];
        for (uint256 i; i < ticks.length; ++i) {
            compare(abi.encodeCall(referenceMath.sqrtPriceAtTick, (ticks[i])));
        }
        uint160[9] memory prices = [uint160(0), 4295128738, 4295128739, 4295128740, 1 << 96,
            TickMath.MAX_SQRT_PRICE - 2, TickMath.MAX_SQRT_PRICE - 1, TickMath.MAX_SQRT_PRICE, type(uint160).max];
        for (uint256 i; i < prices.length; ++i) {
            compare(abi.encodeCall(referenceMath.tickAtSqrtPrice, (prices[i])));
        }
        uint160 unitPrice = abi.decode(compare(abi.encodeCall(referenceMath.sqrtPriceAtTick, (int24(0)))), (uint160));
        require(unitPrice == 1 << 96, "tick zero");
        compare(abi.encodeCall(referenceMath.usableTicks, (int24(0))));
        compare(abi.encodeCall(referenceMath.usableTicks, (int24(-8388608))));
        compare(abi.encodeCall(referenceMath.bits, (uint256(0))));
        compare(abi.encodeCall(referenceMath.mulDiv, (uint256(0), uint256(0), uint256(0), false)));
        compare(abi.encodeCall(referenceMath.mulDiv, (type(uint256).max - 1, type(uint256).max - 1, type(uint256).max - 2, true)));
        compare(abi.encodeCall(referenceMath.mulDiv, (type(uint256).max, type(uint256).max, type(uint256).max - 1, false)));
        for (uint256 bit; bit < 256; ++bit) {
            compare(abi.encodeCall(referenceMath.bits, (uint256(1) << bit)));
            compare(abi.encodeCall(referenceMath.mulDiv, (type(uint256).max, uint256(1) << bit, uint256(1) << bit, true)));
        }
    }
}
