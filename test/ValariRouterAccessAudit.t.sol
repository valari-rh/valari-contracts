// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ValariRouter} from "../src/ValariRouter.sol";
import {ValariRouterTest} from "./ValariRouter.t.sol";

/// @notice Audit regressions using the real local v4 core/periphery/Permit2 fixture.
contract ValariRouterAccessAuditTest is ValariRouterTest {
    struct AccessSnapshot {
        uint256 user0;
        uint256 user1;
        uint256 paid0;
        uint256 paid1;
        uint256 accrued0;
        uint256 accrued1;
    }

    /// @dev Model an ERC20 rejecting only the treasury as a recipient. Neither the
    /// router nor the beneficiary is blocked, and the pool continues operating.
    function testAuditRejectedTreasuryCannotBlockCollectionOrPrincipalExit() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        AccessSnapshot memory b;
        b.user0 = token0.balanceOf(alice);
        b.user1 = token1.balanceOf(alice);
        bytes memory rejected = abi.encodeWithSignature("RecipientBlocked(address)", feeRecipient);
        // Prefix matching rejects every transfer to this recipient, regardless of
        // the amount. Transfers to the user and an alternate destination work.
        bytes memory transferToTreasury =
            abi.encodeWithSelector(IERC20.transfer.selector, feeRecipient);
        vm.mockCallRevert(address(token0), transferToTreasury, rejected);
        vm.mockCallRevert(address(token1), transferToTreasury, rejected);

        {
            ValariRouter.PositionView memory beforePosition = router.getPosition(tokenId);
            assertGt(beforePosition.commission0, 0);
            vm.prank(alice);
            ValariRouter.Payout memory collected = router.collectFees(tokenId, block.timestamp);
            assertEq(positionManager.ownerOf(tokenId), address(router));
            assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
            assertEq(collected.commission0, beforePosition.fees0 / 10);
            assertEq(collected.commission1, beforePosition.fees1 / 10);
            assertEq(token0.balanceOf(alice) - b.user0, collected.amount0);
            assertEq(token1.balanceOf(alice) - b.user1, collected.amount1);
            assertEq(
                router.claimableCommission(feeRecipient, address(token0)), collected.commission0
            );
            assertEq(
                router.claimableCommission(feeRecipient, address(token1)), collected.commission1
            );
            b.paid0 = collected.amount0;
            b.paid1 = collected.amount1;
            b.accrued0 = collected.commission0;
            b.accrued1 = collected.commission1;
        }

        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        {
            ValariRouter.PositionView memory beforeExit = router.getPosition(tokenId);
            vm.prank(alice);
            ValariRouter.Payout memory exited = router.exitPosition(
                tokenId, uint128(beforeExit.amount0), uint128(beforeExit.amount1), block.timestamp
            );
            assertEq(exited.principal0, beforeExit.amount0);
            assertEq(exited.principal1, beforeExit.amount1);
            assertEq(token0.balanceOf(alice) - b.user0, b.paid0 + exited.amount0);
            assertEq(token1.balanceOf(alice) - b.user1, b.paid1 + exited.amount1);
            b.accrued0 += exited.commission0;
            b.accrued1 += exited.commission1;
        }
        assertTrue(router.getPosition(tokenId).closed);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), b.accrued0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), b.accrued1);
        assertEq(router.totalClaimableCommission(address(token0)), b.accrued0);
        assertEq(router.totalClaimableCommission(address(token1)), b.accrued1);
        assertEq(token0.balanceOf(address(router)), b.accrued0);
        assertEq(token1.balanceOf(address(router)), b.accrued1);
        assertEq(token0.balanceOf(feeRecipient), 0);
        assertEq(token1.balanceOf(feeRecipient), 0);
        _assertBlockedWithdrawalRecovered(b.accrued0, b.accrued1, rejected);
    }

    function _assertBlockedWithdrawalRecovered(
        uint256 accrued0,
        uint256 accrued1,
        bytes memory rejected
    ) private {
        // A failed treasury withdrawal affects only that claim and rolls back
        // its ledger changes. No owner intervention is required to recover it.
        vm.expectRevert(rejected);
        vm.prank(feeRecipient);
        router.withdrawCommission(address(token0), feeRecipient, accrued0);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), accrued0);
        assertEq(router.totalClaimableCommission(address(token0)), accrued0);
        assertEq(token0.balanceOf(address(router)), accrued0);

        address alternate = makeAddr("audit alternate treasury destination");
        vm.startPrank(feeRecipient);
        router.withdrawCommission(address(token0), alternate, accrued0);
        router.withdrawCommission(address(token1), alternate, accrued1);
        vm.stopPrank();
        assertEq(token0.balanceOf(alternate), accrued0);
        assertEq(token1.balanceOf(alternate), accrued1);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), 0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), 0);
        assertEq(router.totalClaimableCommission(address(token0)), 0);
        assertEq(router.totalClaimableCommission(address(token1)), 0);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
    }
}
