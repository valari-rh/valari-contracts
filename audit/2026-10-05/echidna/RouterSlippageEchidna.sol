// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {RouterEchidna} from "./RouterEchidna.sol";
import {ValariRouter} from "../../../src/ValariRouter.sol";

/// @notice Separate economic property: minLiquidity alone should be rejected as
/// a token-value slippage bound if a later accepted deposit costs >2x the quote
/// at the original 1:1 price. This is deliberately NOT a budget-limit property.
contract RouterSlippageEchidna is RouterEchidna {
    ValariRouter.DepositQuote internal initialQuote;
    bool internal valueBoundHolds = true;

    event Counterexample(uint256 attackSwap, uint128 quotedLiquidity, uint128 mintedLiquidity,
        uint256 quoted0, uint256 quoted1, uint256 spent0, uint256 spent1);

    constructor() {
        _open(0, 10_000 ether, 10_000 ether, -6000, 6000);
        initialQuote = router.previewDeposit(poolId, 1 ether, 100 ether, 600, 1200);
        require(initialQuote.amount1 == 0);
    }

    function actionStaleQuote(uint128 swapAmount) external {
        uint256 amount = 1 ether + uint256(swapAmount) % (10_000 ether);
        try manager.unlock(abi.encode(false, false, amount, uint256(0))) {} catch { return; }
        (bool ok, bytes memory result) = users[1].invoke(address(router), abi.encodeCall(router.openPosition,
            (poolId, uint128(1 ether), uint128(100 ether), int24(600), int24(1200), initialQuote.liquidity, block.timestamp)));
        if (!ok) return;
        (, uint128 liquidity, uint256 spent0, uint256 spent1) = abi.decode(result, (uint256, uint128, uint256, uint256));
        if (spent0 + spent1 > 2 * (initialQuote.amount0 + initialQuote.amount1)) {
            valueBoundHolds = false;
            emit Counterexample(amount, initialQuote.liquidity, liquidity,
                initialQuote.amount0, initialQuote.amount1, spent0, spent1);
        }
    }

    function echidna_slippage_stale_minimum_bounds_initial_price_value() external view returns (bool) {
        return valueBoundHolds;
    }
}
