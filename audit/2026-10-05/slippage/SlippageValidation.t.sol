// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ValariRouterTest} from "../../../test/ValariRouter.t.sol";
import {PriceMover} from "../../../test/ValariRouterPriceBoundPoC.t.sol";
import {ValariRouter} from "../../../src/ValariRouter.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @dev Focused economic validation; production code and existing tests remain untouched.
contract SlippageValidation is ValariRouterTest {
    function testValidationLooseCapsProduceActualNetLossAndPositiveAttackerMark() public {
        _open(bob, 1_000 ether, 1_000 ether, -600, 1800);
        PriceMover attacker = new PriceMover(manager);
        token0.mint(address(attacker), 10_000 ether);
        token1.mint(address(attacker), 10_000 ether);
        uint256 attackerBefore = token0.balanceOf(address(attacker)) + token1.balanceOf(address(attacker));
        uint256 aliceBefore = token0.balanceOf(alice) + token1.balanceOf(alice);
        ValariRouter.DepositQuote memory honest = router.previewDeposit(poolId, 100 ether, 130 ether, 600, 1200);

        attacker.moveTo(key, false, TickMath.getSqrtPriceAtTick(1300));
        vm.prank(alice);
        (uint256 id, uint128 minted, uint256 spent0, uint256 spent1) = router.openPosition(
            poolId, 100 ether, 130 ether, 600, 1200, honest.liquidity * 99 / 100, block.timestamp
        );
        attacker.moveTo(key, true, SQRT_ONE);
        (uint160 price,,,) = stateView.getSlot0(PoolId.wrap(poolId));
        assertEq(price, SQRT_ONE, "pool exactly restored to original 1:1 price");
        vm.prank(alice);
        ValariRouter.Payout memory payout = router.exitPosition(id, 0, 0, block.timestamp);
        uint256 aliceAfter = token0.balanceOf(alice) + token1.balanceOf(alice);
        uint256 attackerAfter = token0.balanceOf(address(attacker)) + token1.balanceOf(address(attacker));
        assertEq(spent0, 0);
        assertLe(spent1, 130 ether, "caller budget was respected");
        assertGt(minted, honest.liquidity, "liquidity increased");
        assertLt(aliceAfter, aliceBefore, "actual realized user loss including net earned fees");
        assertGt(attackerAfter, attackerBefore, "positive attacker mark at restored reference price before gas");
        emit log_named_decimal_uint("Alice actual net loss", aliceBefore - aliceAfter, 18);
        emit log_named_decimal_uint("Alice returned principal", payout.principal0 + payout.principal1, 18);
        emit log_named_decimal_uint("Alice earned gross fees", payout.fees0 + payout.fees1, 18);
        emit log_named_decimal_uint("Alice fee commission", payout.commission0 + payout.commission1, 18);
        emit log_named_decimal_uint("Attacker marked profit before gas", attackerAfter - attackerBefore, 18);
    }

    function testValidationTightOneSidedCapBlocksSameManipulation() public {
        _open(bob, 1_000 ether, 1_000 ether, -600, 1800);
        PriceMover attacker = new PriceMover(manager);
        token0.mint(address(attacker), 10_000 ether);
        token1.mint(address(attacker), 10_000 ether);
        ValariRouter.DepositQuote memory honest = router.previewDeposit(poolId, 100 ether, 130 ether, 600, 1200);
        assertEq(honest.amount1, 0);
        attacker.moveTo(key, false, TickMath.getSqrtPriceAtTick(1300));
        vm.prank(alice);
        vm.expectRevert(ValariRouter.InvalidLiquidity.selector);
        router.openPosition(poolId, 100 ether, 0, 600, 1200, honest.liquidity * 99 / 100, block.timestamp);
    }

    function testValidationFixedLiquidityAloneStillAllowsWorsePriceWithinLooseCaps() public view {
        ValariRouter.DepositQuote memory honest = router.previewDeposit(poolId, 100 ether, 130 ether, 600, 1200);
        uint160 lower = TickMath.getSqrtPriceAtTick(600);
        uint160 upper = TickMath.getSqrtPriceAtTick(1200);
        // Holding liquidity fixed still lets the position flip from 100 token0 to
        // ~109.42 token1. Both fit the caller's original (100,130) maxima, despite
        // a worse acquisition value at reference price 1. A fixed-L change alone
        // therefore does not repair quote-relative price protection.
        uint256 oppositeTokenCost = SqrtPriceMath.getAmount1Delta(lower, upper, honest.liquidity, true);
        assertGt(oppositeTokenCost, honest.amount0);
        assertLe(oppositeTokenCost, 130 ether);
    }
}
