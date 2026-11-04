// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ValariRouterV3Test} from "./ValariRouterV3.t.sol";
import {ValariRouterV3} from "../src/ValariRouterV3.sol";

/// @notice Independent accounting property over actual v4 settlement, not mocked fee growth.
contract ValariRouterV3AccountingAuditTest is ValariRouterV3Test {
    uint256 private constant DUST0 = 137;
    uint256 private constant DUST1 = 251;

    struct BalanceSnapshot {
        address recipient;
        uint256 user0;
        uint256 user1;
        uint256 recipient0;
        uint256 recipient1;
        uint256 credit0;
        uint256 credit1;
        uint256 totalCredit0;
        uint256 totalCredit1;
    }

    function testFuzzAuditAccountingConservationAcrossOverlappingRanges(uint256 seed) public {
        (uint256 aliceId,,,) = _open(alice, BUDGET, BUDGET, -120, 120);
        (uint256 bobId,,,) = _open(bob, 4 * BUDGET, 4 * BUDGET, -1200, 1200);
        token0.mint(address(router), DUST0);
        token1.mint(address(router), DUST1);
        address replacement = makeAddr("accounting replacement treasury");

        // A reproducible mandatory crossing first leaves Alice's narrow range, then
        // brings it back into range. Both phases retain Bob's wider active position.
        manager.unlock(abi.encode(false, true, uint256(150 ether), uint256(0)));
        assertFalse(router.getPosition(aliceId).inRange);
        manager.unlock(abi.encode(false, false, uint256(150 ether), uint256(0)));
        assertTrue(router.getPosition(aliceId).inRange);

        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            // Previously earned commissions remain the original recipient's credit.
            if (i == 6) router.setFeeRecipient(replacement);
            bool zeroForOne = seed & 1 != 0;
            uint256 swapAmount = bound(seed >> 8, 1, 80 ether);
            manager.unlock(abi.encode(false, zeroForOne, swapAmount, uint256(0)));

            // Donations are credited only to currently active ranges. PoolManager
            // rejects donations while no liquidity is active, so skip that state.
            ValariRouterV3.PositionView memory alicePosition = router.getPosition(aliceId);
            ValariRouterV3.PositionView memory bobPosition = router.getPosition(bobId);
            if (alicePosition.inRange || bobPosition.inRange) {
                manager.unlock(
                    abi.encode(true, false, uint256(seed % 503), uint256((seed >> 16) % 701))
                );
            }

            // Alternate beneficiaries; some rounds deliberately leave fees pending.
            if (seed & 2 != 0) _checkAccountingPayout(aliceId, alice, false);
            if (seed & 4 != 0) _checkAccountingPayout(bobId, bob, false);
            if (seed & 8 != 0) _withdrawPortion(feeRecipient, seed);
            if (seed & 16 != 0) _withdrawPortion(replacement, seed >> 32);
        }

        _checkAccountingPayout(aliceId, alice, true);
        _checkAccountingPayout(bobId, bob, true);
        _assertClosedAccounting(aliceId, bobId, replacement);
        _assertAggregateCredit(feeRecipient, replacement);
        _withdrawAll(feeRecipient);
        _withdrawAll(replacement);
        assertEq(token0.balanceOf(address(router)), DUST0);
        assertEq(token1.balanceOf(address(router)), DUST1);
        _assertAggregateCredit(feeRecipient, replacement);
        _assertNoAllowances();
    }

    function _assertClosedAccounting(uint256 aliceId, uint256 bobId, address replacement)
        private
        view
    {
        ValariRouterV3.PositionView memory aliceClosed = router.getPosition(aliceId);
        ValariRouterV3.PositionView memory bobClosed = router.getPosition(bobId);
        assertTrue(aliceClosed.closed);
        assertTrue(bobClosed.closed);
        assertFalse(aliceClosed.exists);
        assertFalse(bobClosed.exists);
        assertEq(aliceClosed.commissionAccrued0, aliceClosed.feesCollected0 / 10);
        assertEq(aliceClosed.commissionAccrued1, aliceClosed.feesCollected1 / 10);
        assertEq(bobClosed.commissionAccrued0, bobClosed.feesCollected0 / 10);
        assertEq(bobClosed.commissionAccrued1, bobClosed.feesCollected1 / 10);
        assertEq(
            token0.balanceOf(feeRecipient) + token0.balanceOf(replacement)
                + router.totalClaimableCommission(address(token0)),
            aliceClosed.commissionAccrued0 + bobClosed.commissionAccrued0
        );
        assertEq(
            token1.balanceOf(feeRecipient) + token1.balanceOf(replacement)
                + router.totalClaimableCommission(address(token1)),
            aliceClosed.commissionAccrued1 + bobClosed.commissionAccrued1
        );
    }

    function _checkAccountingPayout(uint256 id, address beneficiary, bool exit) private {
        ValariRouterV3.PositionView memory beforePosition = router.getPosition(id);
        BalanceSnapshot memory balances = _snapshotBalances(beneficiary);
        vm.prank(beneficiary);
        ValariRouterV3.Payout memory paid = exit
            ? router.exitPosition(
                id,
                uint128(beforePosition.amount0),
                uint128(beforePosition.amount1),
                block.timestamp
            )
            : router.collectFees(id, block.timestamp);

        uint256 principal0 = exit ? beforePosition.amount0 : 0;
        uint256 principal1 = exit ? beforePosition.amount1 : 0;
        _assertPayout(
            paid,
            principal0,
            principal1,
            beforePosition.fees0,
            beforePosition.fees1,
            beforePosition.commission0,
            beforePosition.commission1
        );
        // Compare independent ERC20 balance changes with the on-chain view and payout.
        assertEq(token0.balanceOf(beneficiary) - balances.user0, paid.amount0);
        assertEq(token1.balanceOf(beneficiary) - balances.user1, paid.amount1);
        assertEq(token0.balanceOf(balances.recipient), balances.recipient0);
        assertEq(token1.balanceOf(balances.recipient), balances.recipient1);
        assertEq(
            router.claimableCommission(balances.recipient, address(token0)),
            balances.credit0 + paid.commission0
        );
        assertEq(
            router.claimableCommission(balances.recipient, address(token1)),
            balances.credit1 + paid.commission1
        );
        assertEq(
            router.totalClaimableCommission(address(token0)),
            balances.totalCredit0 + paid.commission0
        );
        assertEq(
            router.totalClaimableCommission(address(token1)),
            balances.totalCredit1 + paid.commission1
        );
        assertEq(paid.amount0 + paid.commission0, principal0 + beforePosition.fees0);
        assertEq(paid.amount1 + paid.commission1, principal1 + beforePosition.fees1);
        assertEq(
            token0.balanceOf(address(router)), DUST0 + balances.totalCredit0 + paid.commission0
        );
        assertEq(
            token1.balanceOf(address(router)), DUST1 + balances.totalCredit1 + paid.commission1
        );

        ValariRouterV3.PositionView memory afterPosition = router.getPosition(id);
        assertEq(afterPosition.feesCollected0, beforePosition.feesCollected0 + paid.fees0);
        assertEq(afterPosition.feesCollected1, beforePosition.feesCollected1 + paid.fees1);
        assertEq(afterPosition.commissionAccrued0, afterPosition.feesCollected0 / 10);
        assertEq(afterPosition.commissionAccrued1, afterPosition.feesCollected1 / 10);
        assertEq(afterPosition.fees0, 0);
        assertEq(afterPosition.fees1, 0);
        if (!exit) {
            assertEq(afterPosition.liquidity, beforePosition.liquidity);
            assertEq(afterPosition.amount0, beforePosition.amount0);
            assertEq(afterPosition.amount1, beforePosition.amount1);
        }
    }

    function _snapshotBalances(address beneficiary)
        private
        view
        returns (BalanceSnapshot memory b)
    {
        b.recipient = router.feeRecipient();
        b.user0 = token0.balanceOf(beneficiary);
        b.user1 = token1.balanceOf(beneficiary);
        b.recipient0 = token0.balanceOf(b.recipient);
        b.recipient1 = token1.balanceOf(b.recipient);
        b.credit0 = router.claimableCommission(b.recipient, address(token0));
        b.credit1 = router.claimableCommission(b.recipient, address(token1));
        b.totalCredit0 = router.totalClaimableCommission(address(token0));
        b.totalCredit1 = router.totalClaimableCommission(address(token1));
    }

    function _withdrawPortion(address recipient, uint256 seed) private {
        _withdrawTokenPortion(recipient, IERC20(address(token0)), seed, DUST0);
        _withdrawTokenPortion(recipient, IERC20(address(token1)), seed >> 64, DUST1);
    }

    function _withdrawTokenPortion(address recipient, IERC20 token, uint256 seed, uint256 dust)
        private
    {
        uint256 credit = router.claimableCommission(recipient, address(token));
        if (credit == 0) return;
        uint256 amount = 1 + seed % credit;
        uint256 beforeBalance = token.balanceOf(recipient);
        uint256 total = router.totalClaimableCommission(address(token));
        vm.prank(recipient);
        router.withdrawCommission(address(token), recipient, amount);
        assertEq(router.claimableCommission(recipient, address(token)), credit - amount);
        assertEq(token.balanceOf(recipient), beforeBalance + amount);
        assertEq(router.totalClaimableCommission(address(token)), total - amount);
        assertEq(token.balanceOf(address(router)), dust + total - amount);
    }

    function _withdrawAll(address recipient) private {
        uint256 credit0 = router.claimableCommission(recipient, address(token0));
        uint256 credit1 = router.claimableCommission(recipient, address(token1));
        vm.startPrank(recipient);
        if (credit0 != 0) router.withdrawCommission(address(token0), recipient, credit0);
        if (credit1 != 0) router.withdrawCommission(address(token1), recipient, credit1);
        vm.stopPrank();
    }

    function _assertAggregateCredit(address first, address second) private view {
        uint256 credit0 = router.claimableCommission(first, address(token0))
            + router.claimableCommission(second, address(token0));
        uint256 credit1 = router.claimableCommission(first, address(token1))
            + router.claimableCommission(second, address(token1));
        assertEq(router.totalClaimableCommission(address(token0)), credit0);
        assertEq(router.totalClaimableCommission(address(token1)), credit1);
        assertEq(token0.balanceOf(address(router)), DUST0 + credit0);
        assertEq(token1.balanceOf(address(router)), DUST1 + credit1);
    }
}
