// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ValariRouter} from "../src/ValariRouter.sol";
import {ValariRouterForkBase} from "./ValariRouterFork.t.sol";

/// @notice Audit regression using the deployed GOOGL token and Uniswap managers.
/// @dev Only the registry's isBlocked(treasury) reply is mocked. Token code remains real.
contract ValariRouterIntegrationAuditTest is ValariRouterForkBase {
    address internal constant STOCK_REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;

    function testForkAuditBlockedTreasuryCannotPreventCollectionOrExit() public onlyFork {
        PoolKey memory key = router.getPoolKey(GOOGL_POOL);
        int24 center = _centerTick(GOOGL_POOL, key.tickSpacing);
        uint256 tokenId =
            _openFor(user, GOOGL_POOL, 10 ether, 10_000e6, center - 1200, center + 1200);
        _donate(key, 10 ether, 0);
        ValariRouter.PositionView memory beforeBlocked = router.getPosition(tokenId);
        assertGt(beforeBlocked.commission0, 0, "Stock commission must be payable");
        assertGt(beforeBlocked.amount0, 0, "User has invested stock principal");
        assertGt(beforeBlocked.amount1, 0, "User has invested USDG principal");

        bytes memory tokenRevert = _blockTreasuryAndProveTokenRejection();
        ValariRouter.Payout memory collected = _collectWhileBlocked(tokenId, beforeBlocked);
        ValariRouter.Payout memory exited = _exitWhileBlocked(tokenId, key, beforeBlocked);
        uint256 accrued = router.claimableCommission(treasury, GOOGL);
        assertEq(accrued, collected.commission0 + exited.commission0);
        assertEq(accrued, (collected.fees0 + exited.fees0) / 10);
        _verifyBlockedClaimAndAlternateDestination(tokenRevert, accrued);
        emit log_named_uint("Blocked recipient audit fork block", block.number);
        emit log_named_uint("Stock commission separately withdrawn", accrued);
    }

    function _blockTreasuryAndProveTokenRejection() internal returns (bytes memory tokenRevert) {
        bytes memory blockedQuery = abi.encodeWithSignature("isBlocked(address)", treasury);
        vm.mockCall(STOCK_REGISTRY, blockedQuery, abi.encode(true));
        // Fund only the sender; deployed token code and other registry replies remain real.
        deal(GOOGL, outsider, 1 ether);
        vm.expectCall(STOCK_REGISTRY, blockedQuery);
        vm.prank(outsider);
        bool accepted;
        (accepted, tokenRevert) = GOOGL.call(abi.encodeCall(IERC20.transfer, (treasury, 1)));
        assertFalse(accepted, "Deployed stock must reject a blocked recipient");
        assertGe(tokenRevert.length, 4, "Stock supplies a concrete revert reason");
    }

    function _collectWhileBlocked(uint256 tokenId, ValariRouter.PositionView memory beforeBlocked)
        internal
        returns (ValariRouter.Payout memory collected)
    {
        IERC20 stock = IERC20(GOOGL);
        IERC20 stable = IERC20(USDG);
        uint256[10] memory beforeBalances = _balances(stock, stable);
        // Collection succeeds while the treasury is blocked: its share remains credited
        // inside the router, and only the user's net fees are transferred immediately.
        vm.prank(user);
        collected = router.collectFees(tokenId, block.timestamp + 300);
        _assertPayout(stock, stable, collected, beforeBalances, beforeBlocked);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), address(router));
        assertEq(positionManager.getPositionLiquidity(tokenId), beforeBlocked.liquidity);
        assertEq(router.feeRecipient(), treasury);
    }

    function _exitWhileBlocked(
        uint256 tokenId,
        PoolKey memory key,
        ValariRouter.PositionView memory beforeBlocked
    ) internal returns (ValariRouter.Payout memory exited) {
        IERC20 stock = IERC20(GOOGL);
        IERC20 stable = IERC20(USDG);
        // New fees and the entire principal remain withdrawable without owner intervention.
        _donate(key, 10 ether, 0);
        ValariRouter.PositionView memory beforeExit = router.getPosition(tokenId);
        uint256[10] memory beforeBalances = _balances(stock, stable);
        vm.prank(user);
        exited = router.exitPosition(
            tokenId, uint128(beforeExit.amount0), uint128(beforeExit.amount1), block.timestamp + 300
        );
        _assertPayout(stock, stable, exited, beforeBalances, beforeExit);
        assertEq(exited.principal0, beforeBlocked.amount0);
        assertEq(exited.principal1, beforeBlocked.amount1);
        assertEq(exited.amount0 - (exited.fees0 - exited.commission0), beforeBlocked.amount0);
        assertEq(exited.amount1 - (exited.fees1 - exited.commission1), beforeBlocked.amount1);
        assertTrue(router.getPosition(tokenId).closed);
        assertFalse(router.getPosition(tokenId).exists);
        assertEq(router.feeRecipient(), treasury);
    }

    function _verifyBlockedClaimAndAlternateDestination(bytes memory tokenRevert, uint256 accrued)
        internal
    {
        IERC20 stock = IERC20(GOOGL);
        IERC20 stable = IERC20(USDG);
        assertEq(router.totalClaimableCommission(GOOGL), accrued);
        assertEq(stock.balanceOf(address(router)), accrued);
        uint256[10] memory beforeBalances = _balances(stock, stable);

        // A rejected treasury withdrawal rolls back only that claim and preserves its credit.
        vm.prank(treasury);
        vm.expectRevert(tokenRevert);
        router.withdrawCommission(GOOGL, treasury, accrued);
        assertEq(abi.encode(_balances(stock, stable)), abi.encode(beforeBalances));
        assertEq(router.claimableCommission(treasury, GOOGL), accrued);
        assertEq(router.totalClaimableCommission(GOOGL), accrued);

        // The credited treasury can select a valid destination itself, even while blocked.
        uint256 destinationBefore = stock.balanceOf(outsider);
        vm.prank(treasury);
        router.withdrawCommission(GOOGL, outsider, accrued);
        assertEq(stock.balanceOf(outsider), destinationBefore + accrued);
        assertEq(stock.balanceOf(treasury), beforeBalances[2]);
        assertEq(stock.balanceOf(user), beforeBalances[0]);
        assertEq(stable.balanceOf(user), beforeBalances[1]);
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(stable.balanceOf(address(router)), 0);
        assertEq(router.claimableCommission(treasury, GOOGL), 0);
        assertEq(router.totalClaimableCommission(GOOGL), 0);
    }
}
