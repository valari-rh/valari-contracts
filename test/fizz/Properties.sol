// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Snapshots} from "./Snapshots.sol";
import {PropertiesAsserts} from "./utils/PropertiesAsserts.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ValariRouterV3} from "../../src/ValariRouterV3.sol";
import {vm} from "./utils/Hevm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Contains the functions that check the properties (invariants)
abstract contract Properties is PropertiesAsserts, Snapshots {

    // ―――――――――――――――――――― Global properties ―――――――――――――――――――――
    // These properties must always hold after any function call.
    // They MUST BE PUBLIC so that fuzzers can find and call them.

    using PositionInfoLibrary for PositionInfo;

    /// @dev Every per-position global loops over at most this many of the newest harness ids.
    uint256 internal constant TAIL = 32;
    /// @dev GL-25's exact form is only evaluated while the campaign has at most this many ids.
    uint256 internal constant EXACT_LIQ_CAP = 64;
    uint256 internal constant PAGE = 100;

    /// @notice GL-01: router balance of every pool token == totalClaimableCommission + seeded dust
    function property_routerBalanceEqualsCommissionPlusDust() public {
        for (uint256 t; t < TOKENS; ++t) {
            eq(
                tokens[t].balanceOf(address(router)),
                router.totalClaimableCommission(address(tokens[t])) + seededDust[t],
                "GL-01: router balance != totalClaimableCommission + seededDust"
            );
        }
    }

    /// @notice GL-02: commission liabilities are backed by the router balance, per token and per recipient
    function property_commissionLiabilitiesBacked() public {
        for (uint256 t; t < TOKENS; ++t) {
            address token = address(tokens[t]);
            uint256 bal = tokens[t].balanceOf(address(router));
            gte(bal, router.totalClaimableCommission(token), "GL-02: router balance < totalClaimableCommission");
            for (uint256 r; r < recipientsEver.length && r < MAX_RECIPIENTS; ++r) {
                lte(router.claimableCommission(recipientsEver[r], token), bal, "GL-02: recipient credit > router balance");
            }
        }
    }

    /// @notice GL-03: sum of every recipient's claimableCommission equals totalClaimableCommission, per token
    function property_creditSumEqualsTotal() public {
        for (uint256 t; t < TOKENS; ++t) {
            address token = address(tokens[t]);
            uint256 sum;
            for (uint256 r; r < recipientsEver.length && r < MAX_RECIPIENTS; ++r) {
                sum += router.claimableCommission(recipientsEver[r], token);
            }
            eq(sum, router.totalClaimableCommission(token), "GL-03: sum of credits != totalClaimableCommission");
        }
    }

    /// @notice GL-04: returned Payout.commission accrued minus withdrawn amounts equals totalClaimableCommission
    function property_creditLedgerConserved() public {
        for (uint256 t; t < TOKENS; ++t) {
            gte(ghosts.commissionAccrued[t], ghosts.commissionWithdrawn[t], "GL-04: withdrawn more commission than accrued");
            eq(
                ghosts.commissionAccrued[t] - ghosts.commissionWithdrawn[t],
                router.totalClaimableCommission(address(tokens[t])),
                "GL-04: harness commission ledger != totalClaimableCommission"
            );
        }
    }

    /// @notice GL-05: per position and currency, commissionAccrued == feesCollected / 10 and never exceeds fees
    function property_commissionIsFloorTenthOfFees() public {
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            ValariRouterV3.PositionView memory v = _mustGetPosition(positionIds[i]);
            eq(v.commissionAccrued0, v.feesCollected0 / 10, "GL-05: commissionAccrued0 != feesCollected0 / 10");
            eq(v.commissionAccrued1, v.feesCollected1 / 10, "GL-05: commissionAccrued1 != feesCollected1 / 10");
            lte(v.commissionAccrued0, v.feesCollected0, "GL-05: commissionAccrued0 > feesCollected0");
            lte(v.commissionAccrued1, v.feesCollected1, "GL-05: commissionAccrued1 > feesCollected1");
        }
    }

    /// @notice GL-06: sum of actors' depositCount == positionCount == harness positionIds.length
    function property_positionCountsConsistent() public {
        uint256 sum;
        for (uint256 a; a < actors.length; ++a) {
            sum += router.depositCount(actors[a]);
        }
        uint256 count = router.positionCount();
        eq(sum, count, "GL-06: sum of depositCount != positionCount");
        eq(count, positionIds.length, "GL-06: positionCount != harness positionIds.length");
    }

    /// @notice GL-07: catalog views reproduce the harness listing in order, keys are frozen, per-stock counts match
    function property_catalogViewsConsistent() public {
        uint256 listedCount;
        for (uint256 p; p < POOLS; ++p) {
            if (listed[p]) ++listedCount;
        }
        eq(router.poolCount(), listedCount, "GL-07: poolCount != number of listed pools");
        eq(ghosts.listOrder.length, listedCount, "GL-07: listOrder ghost out of sync with listed[]");

        bytes32[] memory ids = router.getPoolIds(0, PAGE);
        eq(ids.length, listedCount, "GL-07: getPoolIds length != poolCount");
        for (uint256 i; i < ids.length && i < ghosts.listOrder.length; ++i) {
            t(ids[i] == poolIds[ghosts.listOrder[i]], "GL-07: getPoolIds not in listing order");
        }

        for (uint256 p; p < POOLS; ++p) {
            try router.getPoolKey(poolIds[p]) returns (PoolKey memory key) {
                t(listed[p], "GL-07: getPoolKey succeeded for an unlisted pool");
                t(keccak256(abi.encode(key)) == poolIds[p], "GL-07: listed pool key changed");
            } catch (bytes memory reason) {
                t(!listed[p], "GL-07: getPoolKey reverted for a listed pool");
                t(_selector(reason) == ValariRouterV3.InvalidPool.selector, "GL-07: unlisted getPoolKey wrong selector");
            }
        }

        uint256 stockA = (listed[0] ? 1 : 0) + (listed[1] ? 1 : 0);
        uint256 stockB = listed[2] ? 1 : 0;
        eq(router.stockPoolCount(address(tokens[1])), stockA, "GL-07: stockPoolCount(stockA) mismatch");
        eq(router.stockPoolCount(address(tokens[2])), stockB, "GL-07: stockPoolCount(stockB) mismatch");
        eq(router.stockPoolCount(address(usdg)), 0, "GL-07: USDG listed as a stock");
        eq(router.stockPoolCount(address(router)), 0, "GL-07: router listed as a stock");
        eq(router.stockPoolCount(address(positionManager)), 0, "GL-07: positionManager listed as a stock");
        eq(router.stockPoolCount(address(permit2)), 0, "GL-07: permit2 listed as a stock");
        eq(router.stockPoolCount(address(poolManager)), 0, "GL-07: poolManager listed as a stock");
        eq(stockA + stockB, listedCount, "GL-07: sum of stockPoolCount != poolCount");

        bytes32[] memory a = router.getStockPoolIds(address(tokens[1]), 0, PAGE);
        eq(a.length, stockA, "GL-07: getStockPoolIds(stockA) length");
        uint256 k;
        if (listed[0]) t(a[k++] == poolIds[0], "GL-07: getStockPoolIds(stockA)[0] != pool 0");
        if (listed[1]) t(a[k++] == poolIds[1], "GL-07: getStockPoolIds(stockA) pool 1 out of order");
        bytes32[] memory b = router.getStockPoolIds(address(tokens[2]), 0, PAGE);
        eq(b.length, stockB, "GL-07: getStockPoolIds(stockB) length");
        if (listed[2]) t(b[0] == poolIds[2], "GL-07: getStockPoolIds(stockB)[0] != pool 2");
    }

    /// @notice GL-08: poolCount, stockPoolCount, positionCount, depositCount and nextTokenId never decrease; nextTokenId == 1 + positionCount
    function property_countersMonotone() public {
        uint256 pc = router.poolCount();
        gte(pc, ghosts.lastPoolCount, "GL-08: poolCount decreased");
        ghosts.lastPoolCount = pc;
        for (uint256 tk; tk < TOKENS; ++tk) {
            uint256 spc = router.stockPoolCount(address(tokens[tk]));
            gte(spc, ghosts.lastStockPoolCount[tk], "GL-08: stockPoolCount decreased");
            ghosts.lastStockPoolCount[tk] = spc;
        }
        uint256 posc = router.positionCount();
        gte(posc, ghosts.lastPositionCount, "GL-08: positionCount decreased");
        ghosts.lastPositionCount = posc;
        uint256 next = positionManager.nextTokenId();
        gte(next, ghosts.lastNextTokenId, "GL-08: nextTokenId decreased");
        ghosts.lastNextTokenId = next;
        eq(next, 1 + posc, "GL-08: nextTokenId != 1 + positionCount (someone else minted, or ids rewound)");
        for (uint256 a; a < actors.length; ++a) {
            uint256 dc = router.depositCount(actors[a]);
            gte(dc, ghosts.lastDepositCount[actors[a]], "GL-08: depositCount decreased");
            ghosts.lastDepositCount[actors[a]] = dc;
        }
        if (positionIds.length != 0) {
            uint256 newest = positionIds[positionIds.length - 1];
            t(newest >= 1 && newest < next, "GL-08: newest harness id outside [1, nextTokenId)");
        }
    }

    /// @notice GL-09: the router custodies exactly as many LP NFTs as the harness has open records
    function property_nftCustodyCountMatchesOpen() public {
        eq(
            IERC721(address(positionManager)).balanceOf(address(router)),
            ghosts.openPositions,
            "GL-09: PositionManager.balanceOf(router) != open harness positions"
        );
    }

    /// @notice GL-10: every tracked position is in exactly one of {open, exited, ejected}, consistent with NFT custody and v4 liquidity
    function property_lifecycleCustodyPerPosition() public {
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            uint256 id = positionIds[i];
            ValariRouterV3.PositionView memory v = _mustGetPosition(id);
            address o = _nftOwner(id);
            uint128 liq = positionManager.getPositionLiquidity(id);
            uint8 cb = ghosts.closedBy[id];
            t(v.closed == (cb != CLOSED_OPEN), "GL-10: closed flag disagrees with harness closedBy");
            if (!v.closed) {
                t(o == address(router), "GL-10: open position NFT not held by router");
                t(v.exists, "GL-10: open position view !exists");
                t(v.nftOwner == address(router), "GL-10: open position view nftOwner != router");
                gt(uint256(v.initialLiquidity), 0, "GL-10: open position has zero initialLiquidity");
                eq(uint256(liq), uint256(v.initialLiquidity), "GL-10: open position v4 liquidity != initialLiquidity");
                eq(uint256(v.liquidity), uint256(v.initialLiquidity), "GL-10: open position view liquidity != initialLiquidity");
            } else if (cb == CLOSED_EXITED) {
                t(o == address(0), "GL-10: exited position NFT still exists");
                eq(uint256(liq), 0, "GL-10: exited position still has v4 liquidity");
                t(!v.exists, "GL-10: exited position view exists");
            } else {
                address to = ghosts.ejectedTo[id];
                t(to != address(0) && to != address(router), "GL-10: ejectedTo is zero or the router");
                t(o == to, "GL-10: ejected position NFT not held by ejectedTo");
                eq(uint256(liq), uint256(v.initialLiquidity), "GL-10: ejected position v4 liquidity != initialLiquidity");
                t(v.exists, "GL-10: ejected position view !exists");
            }
            t(!v.closed || o != address(router), "GL-10: closed position NFT still held by router");
        }
    }

    /// @notice GL-11: token supply is closed over {harness, actors, router, poolManager}; PositionManager and Permit2 hold nothing
    function property_tokenSupplyClosed() public {
        for (uint256 t; t < TOKENS; ++t) {
            MockERC20 token = tokens[t];
            uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(router))
                + token.balanceOf(address(poolManager));
            for (uint256 a; a < actors.length; ++a) {
                sum += token.balanceOf(actors[a]);
            }
            eq(token.totalSupply(), sum, "GL-11: totalSupply != harness + actors + router + poolManager");
            eq(
                token.balanceOf(address(positionManager)) + token.balanceOf(address(permit2)),
                0,
                "GL-11: PositionManager / Permit2 hold tokens between calls"
            );
        }
    }

    /// @notice GL-12: actors' aggregate balance == endowment - deposited - donated + paid out + withdrawn (reported amounts are what moved)
    function property_userTokenLedger() public {
        uint256 endowment = actors.length * INITIAL_TOKEN_BALANCE * 1e18;
        for (uint256 t; t < TOKENS; ++t) {
            uint256 sum;
            for (uint256 a; a < actors.length; ++a) {
                sum += tokens[t].balanceOf(actors[a]);
            }
            eq(
                sum + ghosts.userDeposited[t] + ghosts.userDonated[t],
                endowment + ghosts.userPaidOut[t] + ghosts.userWithdrawn[t],
                "GL-12: actors' balances != endowment - deposited - donated + paidOut + withdrawn"
            );
        }
    }

    /// @notice GL-13: the router retains no ERC-20 allowance (Permit2, PositionManager, PoolManager) nor Permit2 authority between calls
    function property_noLingeringTokenAllowances() public {
        for (uint256 t; t < TOKENS; ++t) {
            MockERC20 token = tokens[t];
            eq(token.allowance(address(router), address(permit2)), 0, "GL-13: router -> permit2 allowance != 0");
            eq(token.allowance(address(router), address(positionManager)), 0, "GL-13: router -> positionManager allowance != 0");
            eq(token.allowance(address(router), address(poolManager)), 0, "GL-13: router -> poolManager allowance != 0");
            (uint160 amount, uint48 expiration,) =
                permit2.allowance(address(router), address(token), address(positionManager));
            eq(uint256(amount), 0, "GL-13: Permit2 allowance amount != 0");
            lte(uint256(expiration), block.timestamp, "GL-13: Permit2 allowance expiration in the future");
        }
    }

    /// @notice GL-14: the router never delegates custodied NFTs: no operator approval, no per-token approval, no v4 subscriber
    function property_noNftApprovals() public {
        IERC721 nft = IERC721(address(positionManager));
        for (uint256 a; a < actors.length; ++a) {
            t(!nft.isApprovedForAll(address(router), actors[a]), "GL-14: router approved an actor as operator");
        }
        t(!nft.isApprovedForAll(address(router), address(this)), "GL-14: router approved the harness as operator");
        t(!nft.isApprovedForAll(address(router), address(positionManager)), "GL-14: router approved positionManager as operator");
        t(!nft.isApprovedForAll(address(router), address(permit2)), "GL-14: router approved permit2 as operator");
        t(!nft.isApprovedForAll(address(router), address(poolManager)), "GL-14: router approved poolManager as operator");

        uint256 checked;
        uint256 n = positionIds.length;
        for (uint256 i = n; i > 0 && checked < 8 && n - i < TAIL; --i) {
            uint256 id = positionIds[i - 1];
            if (ghosts.closedBy[id] != CLOSED_OPEN) continue;
            ++checked;
            t(nft.getApproved(id) == address(0), "GL-14: open position has a token approval");
            t(address(positionManager.subscriber(id)) == address(0), "GL-14: open position has a v4 subscriber");
        }
    }

    /// @notice GL-15: feesCollected0/1 and commissionAccrued0/1 never decrease, freeze once closed, and commission <= fees
    function property_accumulatorsMonotoneAndFrozen() public {
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            uint256 id = positionIds[i];
            ValariRouterV3.PositionView memory v = _mustGetPosition(id);
            Acc storage a = ghosts.lastAcc[id];
            gte(v.feesCollected0, a.f0, "GL-15: feesCollected0 decreased");
            gte(v.feesCollected1, a.f1, "GL-15: feesCollected1 decreased");
            gte(v.commissionAccrued0, a.c0, "GL-15: commissionAccrued0 decreased");
            gte(v.commissionAccrued1, a.c1, "GL-15: commissionAccrued1 decreased");
            if (a.closedSeen) {
                eq(v.feesCollected0, a.f0, "GL-15: feesCollected0 changed after close");
                eq(v.feesCollected1, a.f1, "GL-15: feesCollected1 changed after close");
                eq(v.commissionAccrued0, a.c0, "GL-15: commissionAccrued0 changed after close");
                eq(v.commissionAccrued1, a.c1, "GL-15: commissionAccrued1 changed after close");
            }
            lte(v.commissionAccrued0, v.feesCollected0, "GL-15: commissionAccrued0 > feesCollected0");
            lte(v.commissionAccrued1, v.feesCollected1, "GL-15: commissionAccrued1 > feesCollected1");
            a.f0 = v.feesCollected0;
            a.f1 = v.feesCollected1;
            a.c0 = v.commissionAccrued0;
            a.c1 = v.commissionAccrued1;
            if (v.closed) a.closedSeen = true;
        }
    }

    /// @notice GL-16: once a position has been observed closed it stays closed
    function property_closedLatchNeverFlips() public {
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            uint256 id = positionIds[i];
            if (!ghosts.lastAcc[id].closedSeen) continue;
            t(_mustGetPosition(id).closed, "GL-16: closed flag flipped back to false");
        }
    }

    /// @notice GL-17: the nine immutable record fields equal their values at open and agree with depositorOf / poolIndexOf
    function property_recordFieldsImmutable() public {
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            uint256 id = positionIds[i];
            ValariRouterV3.PositionView memory v = _mustGetPosition(id);
            RecordAtOpen storage r = ghosts.recordAtOpen[id];
            t(v.poolId == r.poolId, "GL-17: poolId changed");
            t(v.depositor == r.depositor, "GL-17: depositor changed");
            t(v.owner == r.depositor, "GL-17: owner != depositor at open");
            eq(uint256(v.openedAt), uint256(r.openedAt), "GL-17: openedAt changed");
            eq(int256(v.tickLower), int256(r.tickLower), "GL-17: tickLower changed");
            eq(int256(v.tickUpper), int256(r.tickUpper), "GL-17: tickUpper changed");
            eq(uint256(v.initialLiquidity), uint256(r.initialLiquidity), "GL-17: initialLiquidity changed");
            eq(uint256(v.amount0Deposited), uint256(r.amount0Deposited), "GL-17: amount0Deposited changed");
            eq(uint256(v.amount1Deposited), uint256(r.amount1Deposited), "GL-17: amount1Deposited changed");
            t(v.depositor == depositorOf[id], "GL-17: depositor != harness depositorOf");
            t(v.poolId == poolIds[poolIndexOf[id]], "GL-17: poolId != harness poolIndexOf");
        }
    }

    /// @notice GL-18: an open position's view is self-consistent and agrees with the ERC-721, the pool key and the live pool price/tick
    function property_openPositionViewConsistent() public {
        uint160[POOLS] memory price;
        int24[POOLS] memory tick;
        for (uint256 p; p < POOLS; ++p) {
            (price[p], tick[p],,) = stateView.getSlot0(PoolId.wrap(poolIds[p]));
        }
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            uint256 id = positionIds[i];
            ValariRouterV3.PositionView memory v = _mustGetPosition(id);
            if (v.closed) continue;
            uint256 p = poolIndexOf[id];
            address o = _nftOwner(id);
            eq(v.tokenId, id, "GL-18: view tokenId != id");
            t(v.exists == (o != address(0)), "GL-18: exists != (nftOwner != 0)");
            t(v.nftOwner == o, "GL-18: view nftOwner != ERC721 owner");
            t(v.owner == v.depositor && v.depositor == depositorOf[id], "GL-18: owner/depositor mismatch");
            t(keccak256(abi.encode(v.poolKey)) == poolIds[p], "GL-18: view poolKey != listed key");
            eq(uint256(v.sqrtPriceX96), uint256(price[p]), "GL-18: view sqrtPriceX96 != live pool price");
            bool inRange = tick[p] >= v.tickLower && tick[p] < v.tickUpper;
            t(v.inRange == inRange, "GL-18: inRange disagrees with live tick");
            t(inRange || v.amount0 == 0 || v.amount1 == 0, "GL-18: out-of-range position has two nonzero principal sides");
            eq(v.netFees0 + v.commission0, v.fees0, "GL-18: netFees0 + commission0 != fees0");
            eq(v.netFees1 + v.commission1, v.fees1, "GL-18: netFees1 + commission1 != fees1");
            lte(v.commission0, v.fees0, "GL-18: commission0 > fees0");
            lte(v.commission1, v.fees1, "GL-18: commission1 > fees1");
            eq(uint256(v.liquidity), uint256(v.initialLiquidity), "GL-18: liquidity != initialLiquidity");
            lte(uint256(v.openedAt), block.timestamp, "GL-18: openedAt in the future");
        }
    }

    /// @notice GL-19: a closed position (exited or ejected) exposes no live figures
    function property_closedPositionViewZeroed() public {
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            ValariRouterV3.PositionView memory v = _mustGetPosition(positionIds[i]);
            if (!v.closed) continue;
            eq(uint256(v.liquidity), 0, "GL-19: closed view liquidity != 0");
            eq(uint256(v.sqrtPriceX96), 0, "GL-19: closed view sqrtPriceX96 != 0");
            eq(v.amount0 + v.amount1, 0, "GL-19: closed view principal != 0");
            eq(v.fees0 + v.fees1, 0, "GL-19: closed view fees != 0");
            eq(v.commission0 + v.commission1, 0, "GL-19: closed view commission != 0");
            eq(v.netFees0 + v.netFees1, 0, "GL-19: closed view netFees != 0");
            t(!v.inRange, "GL-19: closed view inRange");
        }
    }

    /// @notice GL-20: feeRecipient is never zero or the router, was recorded by the harness, and mirrors the last successful setFeeRecipient
    function property_feeRecipientValid() public {
        address fr = router.feeRecipient();
        t(fr != address(0) && fr != address(router), "GL-20: feeRecipient is zero or the router");
        t(isRecipientEver[fr], "GL-20: feeRecipient not in recipientsEver");
        t(fr == ghosts.expectedFeeRecipient, "GL-20: feeRecipient != harness mirror");
    }

    /// @notice GL-21: owner() == admin != 0 and pendingOwner() mirrors the harness's two-step tracking
    function property_ownershipMirror() public {
        address o = router.owner();
        t(o == admin && admin != address(0), "GL-21: owner() != admin or zero");
        t(router.pendingOwner() == ghosts.expectedPendingOwner, "GL-21: pendingOwner() != harness mirror");
    }

    /// @notice GL-22: unlisted pools have both flags false and no key; listed pools' flags equal the last values set
    function property_poolFlagsSync() public {
        for (uint256 p; p < POOLS; ++p) {
            bool dd = router.depositsDisabled(poolIds[p]);
            bool ee = router.ejectEnabled(poolIds[p]);
            bool hasKey;
            try router.getPoolKey(poolIds[p]) returns (PoolKey memory) {
                hasKey = true;
            } catch {}
            t(hasKey == listed[p], "GL-22: getPoolKey liveness != listed[p]");
            if (!listed[p]) {
                t(!dd && !ee, "GL-22: unlisted pool has a flag set");
            } else {
                t(dd == ghosts.lastDepositsDisabled[p], "GL-22: depositsDisabled != last value set");
                t(ee == ghosts.lastEjectEnabled[p], "GL-22: ejectEnabled != last value set");
            }
        }
    }

    /// @notice GL-23: getPosition reverts UnknownPosition for id 0 and nextTokenId, and succeeds for every tracked id and a mid-range minted id
    function property_recordDomain() public {
        uint256 next = positionManager.nextTokenId();
        _expectUnknownPosition(0);
        _expectUnknownPosition(next);
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            _mustGetPosition(positionIds[i]);
        }
        if (next > 1) {
            _mustGetPosition(1 + (next - 1) / 2);
        }
    }

    /// @notice GL-24: realized fees per token never exceed donations plus the per-swap LP fee cap (nobody is paid fees the pool never earned)
    function property_noPhantomFees() public {
        for (uint256 t; t < TOKENS; ++t) {
            lte(
                ghosts.feesRealized[t],
                ghosts.donated[t] + ghosts.swapFeeCap[t],
                "GL-24: realized fees exceed donations + swap fee cap"
            );
        }
    }

    /// @notice GL-25: pool active liquidity <= sum of not-burned initialLiquidity, and (<= 64 ids) == sum of in-range position liquidity
    function property_activeLiquidityIsSumOfInRange() public {
        uint256 n = positionIds.length;
        for (uint256 p; p < POOLS; ++p) {
            (, int24 tick,,) = stateView.getSlot0(PoolId.wrap(poolIds[p]));
            uint256 active = stateView.getLiquidity(PoolId.wrap(poolIds[p]));
            lte(active, ghosts.liveLiquidity[p], "GL-25: pool liquidity > harness liveLiquidity");
            if (n > EXACT_LIQ_CAP) continue;
            uint256 sum;
            for (uint256 i; i < n; ++i) {
                uint256 id = positionIds[i];
                if (poolIndexOf[id] != p) continue;
                RecordAtOpen storage r = ghosts.recordAtOpen[id];
                if (tick < r.tickLower || tick >= r.tickUpper) continue;
                sum += positionManager.getPositionLiquidity(id); // 0 once burned
            }
            eq(active, sum, "GL-25: pool liquidity != sum of in-range position liquidity");
        }
    }

    /// @notice GL-26: PositionManager metadata of every not-burned tracked id names the record's listed pool key and ticks, with no subscriber
    function property_recordMatchesV4Metadata() public {
        uint256 n = positionIds.length;
        for (uint256 i = _tailStart(TAIL); i < n; ++i) {
            uint256 id = positionIds[i];
            if (_nftOwner(id) == address(0)) continue;
            (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(id);
            RecordAtOpen storage r = ghosts.recordAtOpen[id];
            t(keccak256(abi.encode(key)) == poolIds[poolIndexOf[id]], "GL-26: v4 pool key != listed key of the record");
            t(address(key.hooks) == address(0), "GL-26: v4 pool key has hooks");
            eq(int256(info.tickLower()), int256(r.tickLower), "GL-26: v4 tickLower != record");
            eq(int256(info.tickUpper()), int256(r.tickUpper), "GL-26: v4 tickUpper != record");
            t(!info.hasSubscriber(), "GL-26: v4 position has a subscriber");
        }
    }

    /// @notice GL-27: per-user views are complete: depositCount / getDepositorPositionIds reproduce the harness list, getUserPositions yields exactly the open ones
    function property_userViewsComplete() public {
        for (uint256 a; a < actors.length; ++a) {
            address u = actors[a];
            uint256 n = router.depositCount(u);
            uint256[] storage mine = ghosts.idsOf[u];
            eq(n, mine.length, "GL-27: depositCount != harness idsOf length");

            // Historical ids, closed included, in open order.
            for (uint256 c; c < n && c < 4 * PAGE; c += PAGE) {
                uint256[] memory ids = router.getDepositorPositionIds(u, c, PAGE);
                uint256 expected = n - c < PAGE ? n - c : PAGE;
                eq(ids.length, expected, "GL-27: getDepositorPositionIds page length");
                for (uint256 i; i < ids.length && c + i < mine.length; ++i) {
                    eq(ids[i], mine[c + i], "GL-27: getDepositorPositionIds out of order");
                }
            }

            // Open positions only, walked with the documented cursor protocol.
            uint256 cursor;
            uint256 open;
            uint256 pages;
            bool complete = n == 0;
            while (cursor < n && pages < 4) {
                (ValariRouterV3.PositionView[] memory views, uint256 nextCursor) =
                    router.getUserPositions(u, cursor, PAGE);
                uint256 expectedNext = cursor + PAGE < n ? cursor + PAGE : n;
                eq(nextCursor, expectedNext, "GL-27: nextCursor != min(cursor + limit, depositCount)");
                lte(views.length, PAGE, "GL-27: getUserPositions page exceeds limit");
                for (uint256 i; i < views.length; ++i) {
                    ValariRouterV3.PositionView memory v = views[i];
                    t(!v.closed, "GL-27: getUserPositions returned a closed position");
                    t(v.exists, "GL-27: getUserPositions returned a non-existent position");
                    t(v.nftOwner == address(router), "GL-27: getUserPositions position not custodied by router");
                    t(v.depositor == u && v.owner == u, "GL-27: getUserPositions position not owned by user");
                    eq(uint256(v.liquidity), uint256(v.initialLiquidity), "GL-27: getUserPositions liquidity != initialLiquidity");
                    t(depositorOf[v.tokenId] == u, "GL-27: getUserPositions id not recorded for user");
                }
                open += views.length;
                cursor = nextCursor;
                ++pages;
                if (cursor == n) complete = true;
            }
            if (complete) {
                eq(open, ghosts.openCountOf[u], "GL-27: open positions returned != harness openCountOf");
            }
        }
    }

    /// @notice GL-28: paginators reject limit 0 / 101, return empty pages past the end, never exceed limit; getUserPositions(0) reverts InvalidOwner
    function property_pageBounds() public {
        address u = actors[0];
        address stock = address(tokens[1]);
        bytes4 bad = ValariRouterV3.InvalidPageSize.selector;

        try router.getPoolIds(0, 0) returns (bytes32[] memory) { t(false, "GL-28: getPoolIds(limit 0) did not revert"); }
        catch (bytes memory r) { t(_selector(r) == bad, "GL-28: getPoolIds(limit 0) wrong selector"); }
        try router.getPoolIds(0, PAGE + 1) returns (bytes32[] memory) { t(false, "GL-28: getPoolIds(limit 101) did not revert"); }
        catch (bytes memory r) { t(_selector(r) == bad, "GL-28: getPoolIds(limit 101) wrong selector"); }
        try router.getStockPoolIds(stock, 0, 0) returns (bytes32[] memory) { t(false, "GL-28: getStockPoolIds(limit 0) did not revert"); }
        catch (bytes memory r) { t(_selector(r) == bad, "GL-28: getStockPoolIds(limit 0) wrong selector"); }
        try router.getStockPoolIds(stock, 0, PAGE + 1) returns (bytes32[] memory) { t(false, "GL-28: getStockPoolIds(limit 101) did not revert"); }
        catch (bytes memory r) { t(_selector(r) == bad, "GL-28: getStockPoolIds(limit 101) wrong selector"); }
        try router.getDepositorPositionIds(u, 0, 0) returns (uint256[] memory) { t(false, "GL-28: getDepositorPositionIds(limit 0) did not revert"); }
        catch (bytes memory r) { t(_selector(r) == bad, "GL-28: getDepositorPositionIds(limit 0) wrong selector"); }
        try router.getDepositorPositionIds(u, 0, PAGE + 1) returns (uint256[] memory) { t(false, "GL-28: getDepositorPositionIds(limit 101) did not revert"); }
        catch (bytes memory r) { t(_selector(r) == bad, "GL-28: getDepositorPositionIds(limit 101) wrong selector"); }
        try router.getUserPositions(u, 0, 0) returns (ValariRouterV3.PositionView[] memory, uint256) { t(false, "GL-28: getUserPositions(limit 0) did not revert"); }
        catch (bytes memory r) { t(_selector(r) == bad, "GL-28: getUserPositions(limit 0) wrong selector"); }
        try router.getUserPositions(u, 0, PAGE + 1) returns (ValariRouterV3.PositionView[] memory, uint256) { t(false, "GL-28: getUserPositions(limit 101) did not revert"); }
        catch (bytes memory r) { t(_selector(r) == bad, "GL-28: getUserPositions(limit 101) wrong selector"); }

        // offset >= length: empty page, never a revert.
        eq(router.getPoolIds(router.poolCount(), 1).length, 0, "GL-28: getPoolIds past the end not empty");
        eq(router.getStockPoolIds(stock, router.stockPoolCount(stock), 1).length, 0, "GL-28: getStockPoolIds past the end not empty");
        uint256 dc = router.depositCount(u);
        eq(router.getDepositorPositionIds(u, dc, 1).length, 0, "GL-28: getDepositorPositionIds past the end not empty");
        (ValariRouterV3.PositionView[] memory views, uint256 nextCursor) = router.getUserPositions(u, dc, 1);
        eq(views.length, 0, "GL-28: getUserPositions past the end not empty");
        eq(nextCursor, dc, "GL-28: getUserPositions past the end nextCursor != depositCount");

        // A page never exceeds limit.
        lte(router.getPoolIds(0, 1).length, 1, "GL-28: getPoolIds page exceeds limit");
        lte(router.getStockPoolIds(stock, 0, 1).length, 1, "GL-28: getStockPoolIds page exceeds limit");
        lte(router.getDepositorPositionIds(u, 0, 1).length, 1, "GL-28: getDepositorPositionIds page exceeds limit");
        (views,) = router.getUserPositions(u, 0, 1);
        lte(views.length, 1, "GL-28: getUserPositions page exceeds limit");

        try router.getUserPositions(address(0), 0, 1) returns (ValariRouterV3.PositionView[] memory, uint256) {
            t(false, "GL-28: getUserPositions(address(0)) did not revert");
        } catch (bytes memory r) {
            t(_selector(r) == ValariRouterV3.InvalidOwner.selector, "GL-28: getUserPositions(address(0)) wrong selector");
        }
    }

    /// @notice GL-29: a credit held by anyone other than the current feeRecipient never increases between observations
    function property_formerRecipientCreditsNonIncreasing() public {
        address fr = router.feeRecipient();
        // A recipient change since the last observation means the previous recipient may have
        // accrued legitimately in between; refresh only on that observation.
        bool changed = fr != ghosts.lastFeeRecipientSeen;
        for (uint256 r; r < recipientsEver.length && r < MAX_RECIPIENTS; ++r) {
            address holder = recipientsEver[r];
            for (uint256 t; t < TOKENS; ++t) {
                uint256 c = router.claimableCommission(holder, address(tokens[t]));
                if (!changed && holder != fr) {
                    lte(c, ghosts.lastCredit[holder][t], "GL-29: former recipient's credit increased");
                }
                ghosts.lastCredit[holder][t] = c;
            }
        }
        ghosts.lastFeeRecipientSeen = fr;
    }

    // ―――――――――――――――――― Global property helpers ――――――――――――――――――

    /// @dev Start index of the newest `cap` entries of `positionIds`.
    function _tailStart(uint256 cap) internal view returns (uint256) {
        uint256 n = positionIds.length;
        return n > cap ? n - cap : 0;
    }

    /// @dev `getPosition` for an id the harness minted; a revert is itself a violation (GL-23).
    function _mustGetPosition(uint256 id) internal returns (ValariRouterV3.PositionView memory v) {
        try router.getPosition(id) returns (ValariRouterV3.PositionView memory got) {
            return got;
        } catch {
            t(false, "getPosition reverted for a minted id");
        }
    }

    /// @dev `getPosition(id)` must revert with `UnknownPosition`.
    function _expectUnknownPosition(uint256 id) internal {
        try router.getPosition(id) returns (ValariRouterV3.PositionView memory) {
            t(false, "GL-23: getPosition succeeded for an id without a record");
        } catch (bytes memory reason) {
            t(_selector(reason) == ValariRouterV3.UnknownPosition.selector, "GL-23: getPosition wrong revert selector");
        }
    }

    /// @dev First four bytes of revert data (0 when the data is shorter).
    function _selector(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(reason, 32))
        }
    }

    // ――――――――――――――――――― Specific properties ――――――――――――――――――――
    // These properties must hold after specific function calls.
    // They MUST BE INTERNAL and called at the end of the relevant handlers.
    //
    // Conventions: `stateBefore` / `stateAfter` are the snapshot pair the calling handler took
    // around the router call (with `snapshotPool` / `snapshotTokenId` / `snapshotPayee` set for
    // the call). Deltas go through `_d` so an unexpected sign is an assertion, never a panic.

    /// @dev Result of a successful `openPosition`, as the open handlers hand it to the properties.
    struct OpenResult {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 pool;
        int24 tickLower;
        int24 tickUpper;
        address depositor;
        uint128 amount0Max;
        uint128 amount1Max;
        bool wasRecorded; // depositorOf[tokenId] != 0 before _recordPosition
    }

    /// @dev A successful collect / exit: who called, who was paid, the returned Payout and the
    ///      position view read immediately before the call.
    struct PayoutCtx {
        uint256 tokenId;
        uint256 pool;
        address caller;
        address payee;
        bool isExit;
        ValariRouterV3.Payout p;
        ValariRouterV3.PositionView v;
    }

    /// @dev Handler-local balance picture for the round-trip handlers (the shared snapshot pair
    ///      is consumed by the inner open / exit calls). Index 0/1 = the pool's currency0/1.
    struct Outer {
        uint256[2] actorBal;
        uint256[2] routerBal;
        uint256[2] pmBal;
        uint256[2] total;
        uint256[2] credit; // feeRecipient's credit at capture time
        uint256[2] sumUsers; // actors + harness
        address feeRecipient;
    }

    /// @dev One cycle of the N-cycle round trip.
    struct Cycle {
        uint256 tokenId;
        uint256 spent0;
        uint256 spent1;
        uint256 actorBal0Before;
        uint256 actorBal1Before;
        ValariRouterV3.Payout p;
    }

    // ───────────────────────── open ─────────────────────────

    /// @notice SP-01: a successful open mints exactly one router-custodied position whose record mirrors the inputs
    function property_openIdentityAndCounts(OpenResult memory r) internal {
        eq(r.tokenId, stateBefore.nextTokenId, "SP-01: tokenId != pre-call nextTokenId");
        eq(positionManager.nextTokenId(), stateBefore.nextTokenId + 1, "SP-01: nextTokenId did not advance by one");
        eq(router.positionCount(), stateBefore.positionCount + 1, "SP-01: positionCount did not rise by one");
        uint256 a = _actorIndex(r.depositor);
        if (a != NONE) {
            eq(router.depositCount(r.depositor), stateBefore.depositCount[a] + 1, "SP-01: depositCount did not rise by one");
        }
        t(!r.wasRecorded, "SP-01: tokenId was already recorded by the harness");
        t(_nftOwner(r.tokenId) == address(router), "SP-01: minted NFT not custodied by the router");
        eq(uint256(positionManager.getPositionLiquidity(r.tokenId)), uint256(r.liquidity), "SP-01: v4 liquidity != returned liquidity");
        ValariRouterV3.PositionView memory v = router.getPosition(r.tokenId);
        t(v.depositor == r.depositor && v.owner == r.depositor, "SP-01: depositor/owner != caller");
        t(v.poolId == poolIds[r.pool], "SP-01: record poolId != requested pool");
        t(v.tickLower == r.tickLower && v.tickUpper == r.tickUpper, "SP-01: record ticks != requested ticks");
        eq(uint256(v.initialLiquidity), uint256(r.liquidity), "SP-01: initialLiquidity != returned liquidity");
        eq(uint256(v.liquidity), uint256(r.liquidity), "SP-01: view liquidity != returned liquidity");
        eq(uint256(v.amount0Deposited), r.amount0, "SP-01: amount0Deposited != returned amount0");
        eq(uint256(v.amount1Deposited), r.amount1, "SP-01: amount1Deposited != returned amount1");
        eq(uint256(v.openedAt), block.timestamp, "SP-01: openedAt != block.timestamp");
        t(!v.closed && v.exists, "SP-01: fresh position not open / not existing");
        eq(v.feesCollected0 + v.feesCollected1 + v.commissionAccrued0 + v.commissionAccrued1, 0, "SP-01: fresh position has nonzero accumulators");
        uint256 n = router.depositCount(r.depositor);
        uint256[] memory ids = router.getDepositorPositionIds(r.depositor, n - 1, 1);
        t(ids.length == 1 && ids[0] == r.tokenId, "SP-01: id is not the depositor's newest id");
    }

    /// @notice SP-02: a successful open moves value only caller -> pool, exactly the returned amounts, within budget, with no commission
    function property_openTokenConservation(OpenResult memory r) internal {
        uint256 t0 = _poolTok(r.pool, false);
        uint256 t1 = _poolTok(r.pool, true);
        uint256 a = _actorIndex(r.depositor);
        eq(stateAfter.routerBal[t0], stateBefore.routerBal[t0], "SP-02: router currency0 balance moved on open");
        eq(stateAfter.routerBal[t1], stateBefore.routerBal[t1], "SP-02: router currency1 balance moved on open");
        if (a != NONE) {
            eq(_d(stateBefore.actorBal[a][t0], stateAfter.actorBal[a][t0]), int256(r.amount0), "SP-02: caller currency0 debit != amount0");
            eq(_d(stateBefore.actorBal[a][t1], stateAfter.actorBal[a][t1]), int256(r.amount1), "SP-02: caller currency1 debit != amount1");
        }
        eq(_d(stateAfter.pmBal[t0], stateBefore.pmBal[t0]), int256(r.amount0), "SP-02: poolManager currency0 credit != amount0");
        eq(_d(stateAfter.pmBal[t1], stateBefore.pmBal[t1]), int256(r.amount1), "SP-02: poolManager currency1 credit != amount1");
        lte(r.amount0, uint256(r.amount0Max), "SP-02: amount0 exceeds amount0Max");
        lte(r.amount1, uint256(r.amount1Max), "SP-02: amount1 exceeds amount1Max");
        gte(r.amount0 + r.amount1, 1, "SP-02: open spent nothing");
        _assertCreditsUnchanged("SP-02");
    }

    /// @notice SP-03: with the pool price unmoved since the quote, execution equals the quote and one-sided ranges spend exactly one token
    function property_openMatchesQuote(OpenResult memory r, ValariRouterV3.DepositQuote memory q) internal {
        if (_price(r.pool) != q.sqrtPriceX96) return; // price moved between quote and open: not applicable
        eq(uint256(r.liquidity), uint256(q.liquidity), "SP-03: minted liquidity != quote");
        eq(r.amount0, q.amount0, "SP-03: spent amount0 != quote");
        eq(r.amount1, q.amount1, "SP-03: spent amount1 != quote");
        ValariRouterV3.PositionView memory v = router.getPosition(r.tokenId);
        eq(v.fees0 + v.fees1, 0, "SP-03: fresh position shows pending fees");
        lte(v.amount0, uint256(v.amount0Deposited), "SP-03: view amount0 > amount0Deposited");
        lte(v.amount1, uint256(v.amount1Deposited), "SP-03: view amount1 > amount1Deposited");
        uint160 lo = TickMath.getSqrtPriceAtTick(r.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(r.tickUpper);
        if (q.sqrtPriceX96 <= lo) {
            t(r.amount1 == 0 && r.amount0 > 0, "SP-03: price at/below range must spend currency0 only");
        } else if (q.sqrtPriceX96 >= hi) {
            t(r.amount0 == 0 && r.amount1 > 0, "SP-03: price at/above range must spend currency1 only");
        } else {
            t(v.inRange, "SP-03: price strictly inside the range but view not inRange");
        }
    }

    /// @notice SP-04: a successful open changes nothing else (credits, router balances, admin, flags, other positions) and leaves no allowance
    function property_openNoCollateralChanges(OpenResult memory r) internal {
        _assertCreditsUnchanged("SP-04");
        for (uint256 tk; tk < TOKENS; ++tk) {
            eq(stateAfter.routerBal[tk], stateBefore.routerBal[tk], "SP-04: router balance moved on open");
        }
        _assertAdminUnchanged("SP-04");
        eq(router.poolCount(), stateBefore.poolCount, "SP-04: poolCount changed on open");
        _assertFlagsUnchanged("SP-04");
        _assertSamplesUnchanged("SP-04");
        MockERC20 tok0 = _token(r.pool, false);
        MockERC20 tok1 = _token(r.pool, true);
        eq(tok0.allowance(address(router), address(permit2)), 0, "SP-04: currency0 allowance to permit2 left behind");
        eq(tok1.allowance(address(router), address(permit2)), 0, "SP-04: currency1 allowance to permit2 left behind");
        (uint160 amt0,,) = permit2.allowance(address(router), address(tok0), address(positionManager));
        (uint160 amt1,,) = permit2.allowance(address(router), address(tok1), address(positionManager));
        eq(uint256(amt0), 0, "SP-04: Permit2 currency0 allowance left behind");
        eq(uint256(amt1), 0, "SP-04: Permit2 currency1 allowance left behind");
    }

    /// @notice SP-05: a successful open is on a listed pool with deposits enabled; a disabled pool reverts DepositsDisabled
    function property_openGate(bool ok, bytes memory reason, uint256 pool, bool wasDisabled) internal {
        if (ok) {
            t(listed[pool] && !wasDisabled, "SP-05: open succeeded on an unlisted or deposits-disabled pool");
        } else if (wasDisabled) {
            t(_selector(reason) == ValariRouterV3.DepositsDisabled.selector, "SP-05: disabled pool did not revert DepositsDisabled");
        }
    }

    /// @notice SP-06: a same-transaction quote-then-open with containing bounds, min <= quote and budgets <= balance reverts only when deposits are disabled
    function property_depositLiveness(bool ok, bytes memory reason, bool wasDisabled) internal {
        if (!ok && !wasDisabled) {
            t(false, string.concat("SP-06: fresh quote-then-open reverted: ", _reasonName(reason)));
        }
    }

    /// @notice SP-07: no free liquidity: something was spent, v4 liquidity is positive and does not exceed what the spent amounts support
    function property_noFreeLiquidity(OpenResult memory r) internal {
        gte(r.amount0 + r.amount1, 1, "SP-07: liquidity minted for nothing");
        gt(uint256(positionManager.getPositionLiquidity(r.tokenId)), 0, "SP-07: minted position has zero v4 liquidity");
        uint128 supported = LiquidityAmounts.getLiquidityForAmounts(
            _price(r.pool),
            TickMath.getSqrtPriceAtTick(r.tickLower),
            TickMath.getSqrtPriceAtTick(r.tickUpper),
            r.amount0,
            r.amount1
        );
        lte(uint256(r.liquidity), uint256(supported), "SP-07: minted liquidity exceeds what the spent amounts support");
    }

    /// @notice SP-08: a stale quote cannot be abused: a successful open executed at the live post-swap price inside the bounds; a rejected one is a no-op
    function property_staleQuoteOpen(
        bool ok,
        bytes memory,
        OpenResult memory r,
        ValariRouterV3.DepositQuote memory q,
        uint160 live,
        uint160 lo,
        uint160 hi
    ) internal {
        uint256 t0 = _poolTok(r.pool, false);
        uint256 t1 = _poolTok(r.pool, true);
        uint256 a = _actorIndex(r.depositor);
        if (ok) {
            t(lo <= live && live <= hi, "SP-08: open executed at a price outside the caller's bounds");
            ValariRouterV3.PositionView memory v = router.getPosition(r.tokenId);
            eq(uint256(v.sqrtPriceX96), uint256(live), "SP-08: view price != live price sampled before the open");
            gte(uint256(r.liquidity), uint256(q.liquidity), "SP-08: minted below the stale quote used as minLiquidity");
            eq(uint256(positionManager.getPositionLiquidity(r.tokenId)), uint256(r.liquidity), "SP-08: v4 liquidity != returned liquidity");
            if (a != NONE) {
                eq(_d(stateBefore.actorBal[a][t0], stateAfter.actorBal[a][t0]), int256(r.amount0), "SP-08: caller currency0 debit != amount0");
                eq(_d(stateBefore.actorBal[a][t1], stateAfter.actorBal[a][t1]), int256(r.amount1), "SP-08: caller currency1 debit != amount1");
            }
            lte(r.amount0, uint256(r.amount0Max), "SP-08: amount0 exceeds budget");
            lte(r.amount1, uint256(r.amount1Max), "SP-08: amount1 exceeds budget");
            eq(stateAfter.routerBal[t0], stateBefore.routerBal[t0], "SP-08: router currency0 balance moved");
            eq(stateAfter.routerBal[t1], stateBefore.routerBal[t1], "SP-08: router currency1 balance moved");
            t(v.depositor == r.depositor, "SP-08: depositor != caller");
        } else {
            eq(router.positionCount(), stateBefore.positionCount, "SP-08: positionCount changed on a rejected open");
            if (a != NONE) {
                eq(router.depositCount(r.depositor), stateBefore.depositCount[a], "SP-08: depositCount changed on a rejected open");
                eq(stateAfter.actorBal[a][t0], stateBefore.actorBal[a][t0], "SP-08: caller currency0 moved on a rejected open");
                eq(stateAfter.actorBal[a][t1], stateBefore.actorBal[a][t1], "SP-08: caller currency1 moved on a rejected open");
            }
            eq(positionManager.nextTokenId(), stateBefore.nextTokenId, "SP-08: nextTokenId changed on a rejected open");
            eq(stateAfter.routerBal[t0], stateBefore.routerBal[t0], "SP-08: router currency0 moved on a rejected open");
            eq(stateAfter.routerBal[t1], stateBefore.routerBal[t1], "SP-08: router currency1 moved on a rejected open");
        }
    }

    /// @notice SP-09: bounds excluding the live price by one unit always revert PriceOutOfBounds and move nothing
    /// @dev The router checks depositsDisabled (L313) before the price bounds (L316), so on a
    ///      pool the admin dispatcher disabled the expected selector is DepositsDisabled.
    function property_outsideBoundsReverts(bool ok, bytes memory reason, bytes32 poolId) internal {
        t(!ok, "SP-09: open succeeded with bounds that exclude the live price");
        bytes4 want = router.depositsDisabled(poolId)
            ? ValariRouterV3.DepositsDisabled.selector
            : ValariRouterV3.PriceOutOfBounds.selector;
        t(_selector(reason) == want, string.concat("SP-09: unexpected revert: ", _reasonName(reason)));
        eq(positionManager.nextTokenId(), stateBefore.nextTokenId, "SP-09: nextTokenId changed");
        eq(router.positionCount(), stateBefore.positionCount, "SP-09: positionCount changed");
        _assertBalancesUnchanged("SP-09");
    }

    /// @notice SP-10: zero inputs are rejected before any token moves (previewDeposit zero budgets / needed side; open minLiquidity 0 / sqrtPriceMin 0)
    /// @param which 0 = preview(0,0), 1 = preview with 0 on the needed side, 2 = open minLiquidity 0, 3 = open sqrtPriceMin 0
    function property_zeroInputGuards(uint8 which, bool ok, bytes memory reason) internal {
        t(!ok, "SP-10: zero input was accepted");
        bytes4 want = which == 3 ? ValariRouterV3.InvalidPriceBounds.selector : ValariRouterV3.InvalidLiquidity.selector;
        t(_selector(reason) == want, string.concat("SP-10: unexpected revert for a zero input: ", _reasonName(reason)));
        if (which >= 2) {
            eq(positionManager.nextTokenId(), stateBefore.nextTokenId, "SP-10: nextTokenId changed");
            eq(router.positionCount(), stateBefore.positionCount, "SP-10: positionCount changed");
            _assertBalancesUnchanged("SP-10");
        }
    }

    /// @notice SP-11: previewDeposit is monotone in the budgets and never quotes more than the budgets
    function property_previewMonotone(
        ValariRouterV3.DepositQuote memory q,
        ValariRouterV3.DepositQuote memory q2,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal {
        gte(uint256(q2.liquidity), uint256(q.liquidity), "SP-11: larger budgets quoted less liquidity");
        gte(q2.amount0, q.amount0, "SP-11: larger budgets quoted less amount0");
        gte(q2.amount1, q.amount1, "SP-11: larger budgets quoted less amount1");
        lte(q.amount0, uint256(amount0Max), "SP-11: quoted amount0 exceeds budget");
        lte(q.amount1, uint256(amount1Max), "SP-11: quoted amount1 exceeds budget");
    }

    /// @notice SP-12: previewDeposit never rejects a budget the liquidity math accepts (0 < L <= int128.max) and quotes exactly L
    function property_previewNoFalseReject(bool ok, bytes memory reason, uint128 expected, uint128 quoted) internal {
        if (expected == 0 || expected > uint128(type(int128).max)) return;
        if (!ok) {
            ghosts.previewFalseRejects += 1;
            t(false, string.concat("SP-12: previewDeposit rejected a budget the liquidity math accepts: ", _reasonName(reason)));
        }
        eq(uint256(quoted), uint256(expected), "SP-12: quoted liquidity != getLiquidityForAmounts");
    }

    // ─────────────────────── collect / exit ───────────────────────

    /// @notice SP-13: every successful collect/exit is zero-sum across pool, payee and router per currency, and credits/records rise by exactly the reported figures
    function property_payoutConservation(PayoutCtx memory c) internal {
        uint256[2] memory tk = [_poolTok(c.pool, false), _poolTok(c.pool, true)];
        uint256[2] memory amount = [c.p.amount0, c.p.amount1];
        uint256[2] memory commission = [c.p.commission0, c.p.commission1];
        uint256[2] memory principal = [c.p.principal0, c.p.principal1];
        uint256[2] memory fees = [c.p.fees0, c.p.fees1];
        uint256 fr = _recipientIndex(stateBefore.feeRecipient);
        for (uint256 i; i < 2; ++i) {
            eq(amount[i] + commission[i], principal[i] + fees[i], "SP-13: amount + commission != principal + fees");
            eq(_d(stateBefore.pmBal[tk[i]], stateAfter.pmBal[tk[i]]), int256(principal[i] + fees[i]), "SP-13: pool delivered != principal + fees");
            eq(_d(stateAfter.payeeBal[tk[i]], stateBefore.payeeBal[tk[i]]), int256(amount[i]), "SP-13: payee gain != amount");
            eq(_d(stateAfter.routerBal[tk[i]], stateBefore.routerBal[tk[i]]), int256(commission[i]), "SP-13: router retained != commission");
            lte(stateAfter.routerBal[tk[i]], stateBefore.routerBal[tk[i]] + commission[i] + router.MAX_PAYOUT_DUST(), "SP-13: router retained more than commission + MAX_PAYOUT_DUST");
            eq(_d(stateAfter.totalClaimable[tk[i]], stateBefore.totalClaimable[tk[i]]), int256(commission[i]), "SP-13: totalClaimableCommission delta != commission");
            if (fr != NONE) {
                eq(_d(stateAfter.credit[fr][tk[i]], stateBefore.credit[fr][tk[i]]), int256(commission[i]), "SP-13: feeRecipient credit delta != commission");
            }
        }
        ValariRouterV3.PositionView memory v = router.getPosition(c.tokenId);
        eq(_d(v.feesCollected0, stateBefore.posFeesCollected0), int256(c.p.fees0), "SP-13: feesCollected0 delta != fees0");
        eq(_d(v.feesCollected1, stateBefore.posFeesCollected1), int256(c.p.fees1), "SP-13: feesCollected1 delta != fees1");
        eq(_d(v.commissionAccrued0, stateBefore.posCommissionAccrued0), int256(c.p.commission0), "SP-13: commissionAccrued0 delta != commission0");
        eq(_d(v.commissionAccrued1, stateBefore.posCommissionAccrued1), int256(c.p.commission1), "SP-13: commissionAccrued1 delta != commission1");
        for (uint256 r; r < recipientsEver.length && r < MAX_RECIPIENTS; ++r) {
            if (r == fr) continue;
            for (uint256 x; x < TOKENS; ++x) {
                eq(stateAfter.credit[r][x], stateBefore.credit[r][x], "SP-13: another recipient's credit changed");
            }
        }
        for (uint256 x; x < TOKENS; ++x) {
            if (x == tk[0] || x == tk[1]) continue;
            eq(stateAfter.totalClaimable[x], stateBefore.totalClaimable[x], "SP-13: third token's total liability changed");
            eq(stateAfter.routerBal[x], stateBefore.routerBal[x], "SP-13: third token's router balance changed");
        }
        if (!c.isExit) eq(c.p.principal0 + c.p.principal1, 0, "SP-13: collect reported principal");
        if (c.payee != c.caller) {
            eq(stateAfter.depositorBal[tk[0]], stateBefore.depositorBal[tk[0]], "SP-13: *To payout touched the depositor's currency0");
            eq(stateAfter.depositorBal[tk[1]], stateBefore.depositorBal[tk[1]], "SP-13: *To payout touched the depositor's currency1");
        }
    }

    /// @notice SP-14: per-call commission is the floor-of-cumulative carry, never above fees, never below 1 for fees >= 10, and never taxes principal
    function property_payoutCommissionCarry(PayoutCtx memory c) internal {
        ValariRouterV3.PositionView memory v = router.getPosition(c.tokenId);
        eq(int256(c.p.commission0), _d(v.feesCollected0 / 10, stateBefore.posFeesCollected0 / 10), "SP-14: commission0 != floor carry of cumulative fees0");
        eq(int256(c.p.commission1), _d(v.feesCollected1 / 10, stateBefore.posFeesCollected1 / 10), "SP-14: commission1 != floor carry of cumulative fees1");
        lte(c.p.commission0, c.p.fees0, "SP-14: commission0 > fees0");
        lte(c.p.commission1, c.p.fees1, "SP-14: commission1 > fees1");
        if (c.p.fees0 >= 10) gte(c.p.commission0, 1, "SP-14: fees0 >= 10 but commission0 == 0");
        if (c.p.fees1 >= 10) gte(c.p.commission1, 1, "SP-14: fees1 >= 10 but commission1 == 0");
        gte(c.p.amount0, c.p.principal0, "SP-14: payout amount0 below principal0");
        gte(c.p.amount1, c.p.principal1, "SP-14: payout amount1 below principal1");
        eq(v.commissionAccrued0, v.feesCollected0 / 10, "SP-14: commissionAccrued0 != feesCollected0 / 10");
        eq(v.commissionAccrued1, v.feesCollected1 / 10, "SP-14: commissionAccrued1 != feesCollected1 / 10");
    }

    /// @notice SP-15: the exit principal equals exactly the view principal read immediately before; a collect reports zero principal
    function property_exitPrincipalMatchesView(PayoutCtx memory c) internal {
        if (c.isExit) {
            eq(c.p.principal0, c.v.amount0, "SP-15: exit principal0 != view amount0");
            eq(c.p.principal1, c.v.amount1, "SP-15: exit principal1 != view amount1");
        } else {
            eq(c.p.principal0 + c.p.principal1, 0, "SP-15: collect reported principal");
        }
    }

    /// @notice SP-16: the view predicts the payout (fees, commission, amount); a collect zeroes pending fees and leaves principal/range intact; other positions' fees untouched
    function property_payoutFeesMatchView(PayoutCtx memory c) internal {
        eq(c.p.fees0, c.v.fees0, "SP-16: payout fees0 != view fees0");
        eq(c.p.fees1, c.v.fees1, "SP-16: payout fees1 != view fees1");
        eq(c.p.commission0, c.v.commission0, "SP-16: payout commission0 != view commission0");
        eq(c.p.commission1, c.v.commission1, "SP-16: payout commission1 != view commission1");
        eq(c.p.amount0, c.v.netFees0 + (c.isExit ? c.v.amount0 : 0), "SP-16: payout amount0 != view netFees0 (+ principal on exit)");
        eq(c.p.amount1, c.v.netFees1 + (c.isExit ? c.v.amount1 : 0), "SP-16: payout amount1 != view netFees1 (+ principal on exit)");
        if (!c.isExit) {
            ValariRouterV3.PositionView memory v2 = router.getPosition(c.tokenId);
            eq(v2.fees0 + v2.fees1 + v2.netFees0 + v2.netFees1, 0, "SP-16: pending fees not zero right after a collect");
            eq(uint256(v2.liquidity), uint256(v2.initialLiquidity), "SP-16: liquidity changed by a collect");
            eq(v2.amount0, c.v.amount0, "SP-16: principal amount0 changed by a collect");
            eq(v2.amount1, c.v.amount1, "SP-16: principal amount1 changed by a collect");
            t(v2.inRange == c.v.inRange, "SP-16: inRange changed by a collect");
        }
        uint256 checked;
        for (uint256 i; i < stateBefore.sampleCount && checked < 4; ++i) {
            if (stateBefore.sampleIds[i] == c.tokenId || stateBefore.sampleClosed[i]) continue;
            eq(stateAfter.sampleFees0[i], stateBefore.sampleFees0[i], "SP-16: another position's pending fees0 changed");
            eq(stateAfter.sampleFees1[i], stateBefore.sampleFees1[i], "SP-16: another position's pending fees1 changed");
            ++checked;
        }
    }

    /// @notice SP-17: after a collect the position is still open and custodied with unchanged liquidity, record and counts; no principal paid
    function property_collectPostconditions(PayoutCtx memory c) internal {
        ValariRouterV3.PositionView memory v = router.getPosition(c.tokenId);
        t(!v.closed && v.exists, "SP-17: position not open after a collect");
        t(_nftOwner(c.tokenId) == address(router), "SP-17: NFT left the router on a collect");
        uint256 liq = positionManager.getPositionLiquidity(c.tokenId);
        eq(liq, uint256(stateBefore.posPmLiq), "SP-17: v4 liquidity changed by a collect");
        eq(liq, uint256(v.initialLiquidity), "SP-17: v4 liquidity != initialLiquidity");
        _assertCountsUnchanged("SP-17");
        _assertImmutableFields(v, c.v, "SP-17");
        eq(c.p.principal0 + c.p.principal1, 0, "SP-17: collect paid principal");
        eq(stateAfter.nftRouter, stateBefore.nftRouter, "SP-17: router NFT count changed by a collect");
    }

    /// @notice SP-18: after an exit the record is closed but readable, the NFT is burned, v4 liquidity is 0, counts unchanged, router NFT count -1, and the id is gone from getUserPositions
    function property_exitPostconditions(PayoutCtx memory c) internal {
        ValariRouterV3.PositionView memory v;
        try router.getPosition(c.tokenId) returns (ValariRouterV3.PositionView memory x) {
            v = x;
        } catch {
            t(false, "SP-18: exited record no longer resolves");
            return;
        }
        t(v.closed && !v.exists, "SP-18: exited position not (closed && !exists)");
        t(_nftOwner(c.tokenId) == address(0), "SP-18: NFT still exists after exit");
        eq(uint256(positionManager.getPositionLiquidity(c.tokenId)), 0, "SP-18: v4 liquidity not zero after exit");
        _assertImmutableFields(v, c.v, "SP-18");
        _assertCountsUnchanged("SP-18");
        eq(_d(stateBefore.nftRouter, stateAfter.nftRouter), int256(1), "SP-18: router NFT count did not fall by one");
        uint256 n = router.depositCount(c.caller);
        uint256 cursor;
        uint256 pages;
        while (cursor < n && pages < 4) {
            (ValariRouterV3.PositionView[] memory ps, uint256 next) = router.getUserPositions(c.caller, cursor, PAGE);
            for (uint256 k; k < ps.length; ++k) {
                t(ps[k].tokenId != c.tokenId, "SP-18: exited id still listed by getUserPositions");
            }
            cursor = next;
            ++pages;
        }
    }

    /// @notice SP-19: a second consecutive collect with no pool activity pays nothing and changes nothing
    function property_collectTwiceIdempotent(uint256 tokenId, ValariRouterV3.Payout memory p2) internal {
        eq(
            p2.fees0 + p2.fees1 + p2.commission0 + p2.commission1 + p2.amount0 + p2.amount1 + p2.principal0 + p2.principal1,
            0,
            "SP-19: second consecutive collect paid something"
        );
        eq(stateAfter.posFeesCollected0, stateBefore.posFeesCollected0, "SP-19: feesCollected0 changed on the second collect");
        eq(stateAfter.posFeesCollected1, stateBefore.posFeesCollected1, "SP-19: feesCollected1 changed on the second collect");
        eq(stateAfter.posCommissionAccrued0, stateBefore.posCommissionAccrued0, "SP-19: commissionAccrued0 changed on the second collect");
        eq(stateAfter.posCommissionAccrued1, stateBefore.posCommissionAccrued1, "SP-19: commissionAccrued1 changed on the second collect");
        _assertCreditsUnchanged("SP-19");
        for (uint256 tk; tk < TOKENS; ++tk) {
            eq(stateAfter.routerBal[tk], stateBefore.routerBal[tk], "SP-19: router balance changed on the second collect");
            eq(stateAfter.depositorBal[tk], stateBefore.depositorBal[tk], "SP-19: depositor balance changed on the second collect");
        }
        eq(uint256(positionManager.getPositionLiquidity(tokenId)), uint256(stateBefore.posPmLiq), "SP-19: v4 liquidity changed on the second collect");
        t(router.getPosition(tokenId).closed == stateBefore.posClosed, "SP-19: closed flag changed on the second collect");
    }

    /// @notice SP-20: an exit right after a collect (same tx) realizes zero fees and zero commission: receipts == snapshot principal
    function property_collectThenExitNoFees(ValariRouterV3.Payout memory exitP) internal {
        eq(exitP.fees0 + exitP.fees1, 0, "SP-20: exit right after a collect realized fees");
        eq(exitP.commission0 + exitP.commission1, 0, "SP-20: exit right after a collect charged commission");
        eq(exitP.amount0, exitP.principal0, "SP-20: exit amount0 != principal0 with no fees");
        eq(exitP.amount1, exitP.principal1, "SP-20: exit amount1 != principal1 with no fees");
    }

    /// @notice SP-21: at/below the lower boundary the exit principal1 is 0, at/above the upper boundary principal0 is 0, strictly inside it is nonzero
    function property_outOfRangePrincipalOneSided(PayoutCtx memory c) internal {
        if (!c.isExit || c.v.liquidity == 0) return;
        uint160 sp = c.v.sqrtPriceX96;
        uint160 lowP = TickMath.getSqrtPriceAtTick(c.v.tickLower);
        uint160 upP = TickMath.getSqrtPriceAtTick(c.v.tickUpper);
        if (sp <= lowP) eq(c.p.principal1, 0, "SP-21: price at/below range but principal1 != 0");
        else if (sp >= upP) eq(c.p.principal0, 0, "SP-21: price at/above range but principal0 != 0");
        // Dust liquidity legitimately floors to zero on both sides (v4 and _amounts round down);
        // only a position whose live view already shows redeemable principal must pay some out.
        else if (c.v.amount0 + c.v.amount1 > 0) gt(c.p.principal0 + c.p.principal1, 0, "SP-21: in-range exit with liquidity returned no principal");
    }

    /// @notice SP-22: with the pool price exactly on a boundary sqrt price, the open still spends the quote and the exit still delivers the view principal
    function property_boundaryPriceRounding(
        bool isOpen,
        uint256 pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 actual0,
        uint256 actual1,
        uint256 expected0,
        uint256 expected1
    ) internal {
        uint160 sp = _price(pool); // router operations never move the price (SP-44)
        if (sp != TickMath.getSqrtPriceAtTick(tickLower) && sp != TickMath.getSqrtPriceAtTick(tickUpper)) return;
        if (isOpen) {
            eq(actual0, expected0, "SP-22: boundary-price open spent amount0 != quote");
            eq(actual1, expected1, "SP-22: boundary-price open spent amount1 != quote");
            ghosts.boundaryOpens += 1;
        } else {
            eq(actual0, expected0, "SP-22: boundary-price exit principal0 != view");
            eq(actual1, expected1, "SP-22: boundary-price exit principal1 != view");
            ghosts.boundaryExits += 1;
        }
    }

    /// @notice SP-23: on an open, router-custodied position the depositor's collect / exit (mins within the live principal, live deadline) never reverts
    function property_exitCollectLiveness(bool ok, bytes memory reason, string memory what) internal {
        if (!ok) t(false, string.concat("SP-23: ", what, " by the depositor reverted: ", _reasonName(reason)));
    }

    /// @notice SP-24: an exit whose principal minimum exceeds the live principal by one reverts InsufficientProceeds and is a no-op
    function property_failedExitNoop(bool ok, bytes memory reason, uint256 tokenId) internal {
        t(!ok, "SP-24: exit with a minimum above the live principal succeeded");
        t(_selector(reason) == ValariRouterV3.InsufficientProceeds.selector, string.concat("SP-24: unexpected revert: ", _reasonName(reason)));
        t(!router.getPosition(tokenId).closed, "SP-24: record closed by a failed exit");
        t(_nftOwner(tokenId) == address(router), "SP-24: NFT left the router on a failed exit");
        eq(uint256(positionManager.getPositionLiquidity(tokenId)), uint256(stateBefore.posPmLiq), "SP-24: v4 liquidity changed by a failed exit");
        _assertBalancesUnchanged("SP-24");
        _assertCreditsUnchanged("SP-24");
    }

    /// @notice SP-25: a closed or unknown position is dead for every caller: collect/exit/eject revert and nothing changes
    function property_closedPositionsDead(
        bool ok,
        bytes memory reason,
        bool known,
        bool wasClosed,
        address caller,
        uint256 tokenId,
        string memory what
    ) internal {
        if (known && !wasClosed) return;
        t(!ok, string.concat("SP-25: ", what, " succeeded on a closed / unknown position"));
        bytes4 want = !known
            ? ValariRouterV3.UnknownPosition.selector
            : (depositorOf[tokenId] == caller ? ValariRouterV3.PositionClosed.selector : ValariRouterV3.NotPositionOwner.selector);
        t(_selector(reason) == want, string.concat("SP-25: unexpected revert on a dead position: ", _reasonName(reason)));
        t(stateAfter.posClosed == stateBefore.posClosed, "SP-25: closed flag changed");
        t(stateAfter.posNftOwner == stateBefore.posNftOwner, "SP-25: NFT owner changed");
        eq(stateAfter.posFeesCollected0, stateBefore.posFeesCollected0, "SP-25: feesCollected0 changed");
        eq(stateAfter.posFeesCollected1, stateBefore.posFeesCollected1, "SP-25: feesCollected1 changed");
        eq(stateAfter.posCommissionAccrued0, stateBefore.posCommissionAccrued0, "SP-25: commissionAccrued0 changed");
        eq(stateAfter.posCommissionAccrued1, stateBefore.posCommissionAccrued1, "SP-25: commissionAccrued1 changed");
        _assertCreditsUnchanged("SP-25");
    }

    /// @notice SP-26: a non-depositor (the contract owner included) cannot collect, exit or eject: the call reverts NotPositionOwner and nothing changes
    function property_nonDepositorCannotAct(
        bool ok,
        bytes memory reason,
        bool known,
        address caller,
        uint256 tokenId,
        string memory what
    ) internal {
        if (!known || depositorOf[tokenId] == caller) return;
        t(!ok, string.concat("SP-26: ", what, " succeeded for a non-depositor"));
        t(_selector(reason) == ValariRouterV3.NotPositionOwner.selector, string.concat("SP-26: unexpected revert for a non-depositor: ", _reasonName(reason)));
        _assertBalancesUnchanged("SP-26");
        _assertCreditsUnchanged("SP-26");
        t(stateAfter.posClosed == stateBefore.posClosed, "SP-26: closed flag changed");
        t(stateAfter.posNftOwner == stateBefore.posNftOwner, "SP-26: NFT owner changed");
        eq(uint256(stateAfter.posPmLiq), uint256(stateBefore.posPmLiq), "SP-26: v4 liquidity changed");
        eq(stateAfter.nftRouter, stateBefore.nftRouter, "SP-26: router NFT count changed");
    }

    // ───────────────────────── round trips ─────────────────────────

    /// @notice SP-27: per cycle of the N-cycle open->exit round trip: no fees, no commission, returned <= spent, actor balances non-increasing
    function property_roundTripNoProfitN_cycle(Cycle memory c, uint256 pool, address who) internal {
        eq(c.p.fees0 + c.p.fees1, 0, "SP-27: round-trip cycle realized fees");
        eq(c.p.commission0 + c.p.commission1, 0, "SP-27: round-trip cycle charged commission");
        lte(c.p.amount0, c.spent0, "SP-27: cycle returned more currency0 than it spent");
        lte(c.p.amount1, c.spent1, "SP-27: cycle returned more currency1 than it spent");
        lte(_token(pool, false).balanceOf(who), c.actorBal0Before, "SP-27: actor currency0 balance grew over a cycle");
        lte(_token(pool, true).balanceOf(who), c.actorBal1Before, "SP-27: actor currency1 balance grew over a cycle");
    }

    /// @notice SP-27: after N cycles the router, the total liability and the recipient's credit are exactly unchanged and the actor's loss equals the pool's gain
    function property_roundTripNoProfitN(Outer memory before, Outer memory after_) internal {
        for (uint256 i; i < 2; ++i) {
            eq(after_.routerBal[i], before.routerBal[i], "SP-27: router balance changed over the round trip");
            eq(after_.total[i], before.total[i], "SP-27: totalClaimableCommission changed over the round trip");
            eq(after_.credit[i], before.credit[i], "SP-27: feeRecipient credit changed over the round trip");
            eq(_d(before.actorBal[i], after_.actorBal[i]), _d(after_.pmBal[i], before.pmBal[i]), "SP-27: actor loss != pool gain");
        }
    }

    /// @notice SP-28: a single immediate open->exit cycle returns no more than spent, realizes no fees/commission, restores router balances, burns the NFT
    function property_roundTripSingleCycle(
        OpenResult memory r,
        ValariRouterV3.Payout memory p,
        Outer memory before,
        Outer memory after_
    ) internal {
        lte(p.amount0, r.amount0, "SP-28: exit returned more currency0 than the open spent");
        lte(p.amount1, r.amount1, "SP-28: exit returned more currency1 than the open spent");
        for (uint256 i; i < 2; ++i) {
            lte(after_.actorBal[i], before.actorBal[i], "SP-28: actor balance grew over the cycle");
            eq(after_.routerBal[i], before.routerBal[i], "SP-28: router balance changed over the cycle");
            eq(after_.total[i], before.total[i], "SP-28: totalClaimableCommission changed over the cycle");
            eq(after_.credit[i], before.credit[i], "SP-28: feeRecipient credit changed over the cycle");
        }
        eq(p.fees0 + p.fees1, 0, "SP-28: cycle realized fees");
        eq(p.commission0 + p.commission1, 0, "SP-28: cycle charged commission");
        ValariRouterV3.PositionView memory v = router.getPosition(r.tokenId);
        eq(v.feesCollected0 + v.feesCollected1 + v.commissionAccrued0 + v.commissionAccrued1, 0, "SP-28: cycle left nonzero accumulators");
        t(_nftOwner(r.tokenId) == address(0) && v.closed, "SP-28: NFT not burned / record not closed after the cycle");
    }

    /// @notice SP-29: re-quoting the amounts an exit returned, on the same range at the same price, yields no more liquidity than was burned
    function property_roundTripLiquidityNonExpanding(
        uint256 pool,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint128 burned
    ) internal {
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) return;
        try router.previewDeposit(poolIds[pool], uint128(amount0), uint128(amount1), tickLower, tickUpper)
            returns (ValariRouterV3.DepositQuote memory q)
        {
            lte(uint256(q.liquidity), uint256(burned), "SP-29: re-quote of the returned amounts exceeds the burned liquidity");
        } catch {}
    }

    /// @notice SP-30: the ceil/floor gap is at most one raw unit per token (spent vs returned on a round trip; deposited vs view right after an open)
    function property_roundTripGapAtMostOne(uint256 hi0, uint256 lo0, uint256 hi1, uint256 lo1, string memory what) internal {
        t(hi0 >= lo0 && hi0 - lo0 <= 1, string.concat("SP-30: currency0 gap exceeds one unit (", what, ")"));
        t(hi1 >= lo1 && hi1 - lo1 <= 1, string.concat("SP-30: currency1 gap exceeds one unit (", what, ")"));
    }

    /// @notice SP-31: across a round trip the combined user-side balance never increases and the router's holdings do not change
    function property_roundTripUserSideNonIncreasing(Outer memory before, Outer memory after_) internal {
        for (uint256 i; i < 2; ++i) {
            lte(after_.sumUsers[i], before.sumUsers[i], "SP-31: user-side balance increased over the round trip");
            eq(after_.routerBal[i], before.routerBal[i], "SP-31: router balance changed over the round trip");
        }
    }

    /// @notice SP-32: open then immediately collect is a no-op payout: all-zero Payout, liquidity/custody unchanged, actor and router balances unchanged
    function property_openCollectNoop(
        OpenResult memory r,
        ValariRouterV3.Payout memory p,
        Outer memory mid,
        Outer memory after_
    ) internal {
        eq(
            p.fees0 + p.fees1 + p.commission0 + p.commission1 + p.amount0 + p.amount1 + p.principal0 + p.principal1,
            0,
            "SP-32: collect right after open paid something"
        );
        eq(uint256(positionManager.getPositionLiquidity(r.tokenId)), uint256(r.liquidity), "SP-32: v4 liquidity changed");
        t(_nftOwner(r.tokenId) == address(router), "SP-32: NFT left the router");
        for (uint256 i; i < 2; ++i) {
            eq(after_.actorBal[i], mid.actorBal[i], "SP-32: actor balance moved on a no-op collect");
            eq(after_.routerBal[i], mid.routerBal[i], "SP-32: router balance moved on a no-op collect");
        }
    }

    // ───────────────────────── eject ─────────────────────────

    /// @notice SP-33: eject is exactly one NFT move: closed && exists, nftOwner == to, v4 liquidity intact, no token/credit/accumulator/count change, pending fees travel uncharged
    function property_ejectPostconditions(uint256 tokenId, address to, ValariRouterV3.PositionView memory v) internal {
        ValariRouterV3.PositionView memory v2 = router.getPosition(tokenId);
        t(v2.closed && v2.exists, "SP-33: ejected position not (closed && exists)");
        t(v2.nftOwner == to && _nftOwner(tokenId) == to, "SP-33: NFT not held by `to` after eject");
        uint256 liq = positionManager.getPositionLiquidity(tokenId);
        eq(liq, uint256(v.initialLiquidity), "SP-33: v4 liquidity != initialLiquidity after eject");
        eq(liq, uint256(stateBefore.posPmLiq), "SP-33: v4 liquidity changed by eject");
        _assertBalancesUnchanged("SP-33");
        _assertCreditsUnchanged("SP-33");
        eq(v2.feesCollected0, v.feesCollected0, "SP-33: feesCollected0 changed by eject");
        eq(v2.feesCollected1, v.feesCollected1, "SP-33: feesCollected1 changed by eject");
        eq(v2.commissionAccrued0, v.commissionAccrued0, "SP-33: commissionAccrued0 changed by eject");
        eq(v2.commissionAccrued1, v.commissionAccrued1, "SP-33: commissionAccrued1 changed by eject");
        _assertCountsUnchanged("SP-33");
        _assertFlagsUnchanged("SP-33");
        _assertImmutableFields(v2, v, "SP-33");
        eq(_d(stateBefore.nftRouter, stateAfter.nftRouter), int256(1), "SP-33: router NFT count did not fall by one");
        eq(_d(stateAfter.nftPayee, stateBefore.nftPayee), int256(1), "SP-33: `to` NFT count did not rise by one");
        // The uncollected fees the view showed before travel with the NFT, uncharged.
        PoolId pid = PoolId.wrap(v.poolId);
        (uint128 pmLiq, uint256 last0, uint256 last1) =
            stateView.getPositionInfo(pid, address(positionManager), v.tickLower, v.tickUpper, bytes32(tokenId));
        (uint256 g0, uint256 g1) = stateView.getFeeGrowthInside(pid, v.tickLower, v.tickUpper);
        unchecked {
            g0 -= last0;
            g1 -= last1;
        }
        eq(FullMath.mulDiv(g0, pmLiq, 1 << 128), v.fees0, "SP-33: pending fees0 did not travel with the NFT");
        eq(FullMath.mulDiv(g1, pmLiq, 1 << 128), v.fees1, "SP-33: pending fees1 did not travel with the NFT");
    }

    /// @notice SP-34: eject by the depositor to an actor succeeds iff ejectEnabled was set for the pool; otherwise EjectDisabled with the NFT still in custody
    function property_ejectGate(bool ok, bytes memory reason, uint256 tokenId, bool wasEnabled) internal {
        if (ok) {
            t(wasEnabled, "SP-34: eject succeeded while ejectEnabled was false");
        } else {
            t(!wasEnabled, string.concat("SP-34: eject reverted while ejectEnabled was true: ", _reasonName(reason)));
            t(_selector(reason) == ValariRouterV3.EjectDisabled.selector, string.concat("SP-34: unexpected revert: ", _reasonName(reason)));
            t(_nftOwner(tokenId) == address(router), "SP-34: NFT left the router on a refused eject");
            t(!router.getPosition(tokenId).closed, "SP-34: record closed by a refused eject");
        }
    }

    // ───────────────────────── withdraw ─────────────────────────

    /// @notice SP-35: a successful withdraw moves exactly `amount` from credit, total and router balance to `to`; the backing gate held; nothing else changed
    function property_withdrawPostconditions(address caller, address token, uint256 amount, uint256 creditBefore) internal {
        uint256 tk = _tokenIndex(token);
        uint256 cr = _recipientIndex(caller);
        eq(_d(creditBefore, router.claimableCommission(caller, token)), int256(amount), "SP-35: caller credit did not fall by amount");
        eq(_d(stateBefore.totalClaimable[tk], stateAfter.totalClaimable[tk]), int256(amount), "SP-35: total liability did not fall by amount");
        eq(_d(stateBefore.routerBal[tk], stateAfter.routerBal[tk]), int256(amount), "SP-35: router balance did not fall by amount");
        eq(_d(stateAfter.payeeBal[tk], stateBefore.payeeBal[tk]), int256(amount), "SP-35: `to` did not gain amount");
        gte(stateBefore.routerBal[tk], stateBefore.totalClaimable[tk], "SP-35: backing gate did not hold before the withdraw");
        for (uint256 r; r < recipientsEver.length && r < MAX_RECIPIENTS; ++r) {
            for (uint256 x; x < TOKENS; ++x) {
                if (r == cr && x == tk) continue;
                eq(stateAfter.credit[r][x], stateBefore.credit[r][x], "SP-35: another (recipient, token) credit changed");
            }
        }
        for (uint256 x; x < TOKENS; ++x) {
            if (x == tk) continue;
            eq(stateAfter.totalClaimable[x], stateBefore.totalClaimable[x], "SP-35: another token's total liability changed");
            eq(stateAfter.routerBal[x], stateBefore.routerBal[x], "SP-35: another token's router balance changed");
        }
        _assertSamplesUnchanged("SP-35");
        _assertCountsUnchanged("SP-35");
        _assertFlagsUnchanged("SP-35");
    }

    /// @notice SP-36: a credit holder can always withdraw the full credit in one call; it zeroes the credit and moves exactly credit router -> to
    function property_fullWithdrawLiveness(bool ok, bytes memory reason, address caller, address token, uint256 credit) internal {
        if (!ok) {
            t(false, string.concat("SP-36: full-credit withdraw reverted: ", _reasonName(reason)));
            return;
        }
        uint256 tk = _tokenIndex(token);
        eq(router.claimableCommission(caller, token), 0, "SP-36: credit not zero after a full withdraw");
        eq(_d(stateAfter.payeeBal[tk], stateBefore.payeeBal[tk]), int256(credit), "SP-36: `to` did not gain the full credit");
        eq(_d(stateBefore.routerBal[tk], stateAfter.routerBal[tk]), int256(credit), "SP-36: router did not lose the full credit");
    }

    /// @notice SP-37: withdrawing above the credit (incl. anything with zero credit) reverts InsufficientCommission and changes nothing; a success implies amount <= credit
    function property_overdrawReverts(
        bool ok,
        bytes memory reason,
        address caller,
        address token,
        address to,
        uint256 amount,
        uint256 creditBefore
    ) internal {
        if (ok) {
            lte(amount, creditBefore, "SP-37: withdraw succeeded for more than the credit");
            return;
        }
        bool guardsPass = token != address(0) && to != address(0) && to != address(router) && amount != 0;
        if (guardsPass && amount > creditBefore) {
            t(_selector(reason) == ValariRouterV3.InsufficientCommission.selector, string.concat("SP-37: overdraw reverted with: ", _reasonName(reason)));
        }
        eq(router.claimableCommission(caller, token), creditBefore, "SP-37: credit changed by a failed withdraw");
        uint256 tk = _tokenIndexOrNone(token);
        if (tk != NONE) {
            eq(stateAfter.totalClaimable[tk], stateBefore.totalClaimable[tk], "SP-37: total liability changed by a failed withdraw");
            eq(stateAfter.routerBal[tk], stateBefore.routerBal[tk], "SP-37: router balance changed by a failed withdraw");
        }
    }

    // ───────────────────────── admin ─────────────────────────

    /// @notice SP-38: a successful addPool appends the id last with the key stored byte-identically, both flags false, counts +1, nothing else changed, and a duplicate listing reverts DuplicatePool
    function property_addPoolPostconditions(bytes32 id, uint256 pool, bool dupOk, bytes memory dupReason) internal {
        t(id == poolIds[pool], "SP-38: addPool returned an unexpected id");
        eq(router.poolCount(), stateBefore.poolCount + 1, "SP-38: poolCount did not rise by one");
        address stock = Currency.unwrap(poolKeys[pool].currency0) == address(usdg)
            ? Currency.unwrap(poolKeys[pool].currency1)
            : Currency.unwrap(poolKeys[pool].currency0);
        uint256 st = _tokenIndex(stock);
        for (uint256 x; x < TOKENS; ++x) {
            eq(router.stockPoolCount(address(tokens[x])), stateBefore.stockPoolCount[x] + (x == st ? 1 : 0), "SP-38: stockPoolCount delta wrong");
        }
        bytes32[] memory ids = router.getPoolIds(router.poolCount() - 1, 1);
        t(ids.length == 1 && ids[0] == id, "SP-38: id is not the last of getPoolIds");
        ids = router.getStockPoolIds(stock, router.stockPoolCount(stock) - 1, 1);
        t(ids.length == 1 && ids[0] == id, "SP-38: id is not the last of getStockPoolIds");
        t(keccak256(abi.encode(router.getPoolKey(id))) == keccak256(abi.encode(poolKeys[pool])), "SP-38: stored key != listed key");
        t(!router.depositsDisabled(id) && !router.ejectEnabled(id), "SP-38: fresh pool has a flag set");
        for (uint256 q; q < POOLS; ++q) {
            if (q == pool || !listed[q]) continue;
            t(keccak256(abi.encode(router.getPoolKey(poolIds[q]))) == keccak256(abi.encode(poolKeys[q])), "SP-38: a previously listed key changed");
        }
        _assertSamplesUnchanged("SP-38");
        _assertCreditsUnchanged("SP-38");
        _assertBalancesUnchanged("SP-38");
        _assertAdminUnchanged("SP-38");
        eq(router.positionCount(), stateBefore.positionCount, "SP-38: positionCount changed by addPool");
        t(!dupOk, "SP-38: duplicate addPool succeeded");
        t(_selector(dupReason) == ValariRouterV3.DuplicatePool.selector, string.concat("SP-38: duplicate addPool reverted with: ", _reasonName(dupReason)));
    }

    /// @notice SP-39: setDepositsDisabled / setEjectEnabled write exactly the target flag; unlisted pools revert InvalidPool with both flags false
    function property_flagSettersPure(bool ok, bytes memory reason, uint256 pool, bool isDeposits, bool x, bool wasListed) internal {
        bytes32 id = poolIds[pool];
        bool dd = router.depositsDisabled(id);
        bool ee = router.ejectEnabled(id);
        if (wasListed) {
            t(ok, string.concat("SP-39: flag setter reverted on a listed pool: ", _reasonName(reason)));
            t(isDeposits ? dd == x : ee == x, "SP-39: target flag != argument");
            t(isDeposits ? ee == stateBefore.ejectEnabled[pool] : dd == stateBefore.depositsDisabled[pool], "SP-39: sibling flag changed");
        } else {
            t(!ok, "SP-39: flag setter succeeded on an unlisted pool");
            t(_selector(reason) == ValariRouterV3.InvalidPool.selector, string.concat("SP-39: unlisted pool reverted with: ", _reasonName(reason)));
            t(!dd && !ee, "SP-39: unlisted pool has a flag set");
        }
        for (uint256 q; q < POOLS; ++q) {
            if (q == pool) continue;
            t(router.depositsDisabled(poolIds[q]) == stateBefore.depositsDisabled[q], "SP-39: another pool's depositsDisabled changed");
            t(router.ejectEnabled(poolIds[q]) == stateBefore.ejectEnabled[q], "SP-39: another pool's ejectEnabled changed");
        }
        _assertSamplesUnchanged("SP-39");
        _assertBalancesUnchanged("SP-39");
        _assertCreditsUnchanged("SP-39");
        _assertCountsUnchanged("SP-39");
    }

    /// @notice SP-40: setFeeRecipient redirects future accrual only: feeRecipient == n, every credit/total, owner, counts and catalog unchanged
    function property_setFeeRecipientFutureOnly(address n) internal {
        t(router.feeRecipient() == n, "SP-40: feeRecipient != new recipient");
        _assertCreditsUnchanged("SP-40");
        t(router.owner() == stateBefore.owner, "SP-40: owner changed by setFeeRecipient");
        eq(router.positionCount(), stateBefore.positionCount, "SP-40: positionCount changed by setFeeRecipient");
        eq(router.poolCount(), stateBefore.poolCount, "SP-40: poolCount changed by setFeeRecipient");
    }

    /// @notice SP-41: ownership is two-step and non-leaky: transfer sets only pendingOwner (who cannot act yet); accept flips owner, clears pending, and the old owner loses its powers
    function property_ownable2Step(bool isTransfer, address n, address prevOwner) internal {
        if (isTransfer) {
            t(router.pendingOwner() == n, "SP-41: pendingOwner != transfer target");
            t(router.owner() == stateBefore.owner, "SP-41: owner changed by transferOwnership");
            t(router.feeRecipient() == stateBefore.feeRecipient, "SP-41: feeRecipient changed by transferOwnership");
            if (n != router.owner()) {
                bool cur = router.ejectEnabled(poolIds[0]);
                vm.prank(n);
                try router.setEjectEnabled(poolIds[0], cur) {
                    t(false, "SP-41: pending owner could call an owner function");
                } catch {}
            }
        } else {
            t(router.owner() == n && router.pendingOwner() == address(0), "SP-41: acceptOwnership did not flip owner / clear pendingOwner");
            t(router.feeRecipient() == stateBefore.feeRecipient, "SP-41: feeRecipient changed by acceptOwnership");
            _assertCreditsUnchanged("SP-41");
            _assertSamplesUnchanged("SP-41");
            eq(router.poolCount(), stateBefore.poolCount, "SP-41: poolCount changed by acceptOwnership");
            if (prevOwner != n) {
                bool cur = router.depositsDisabled(poolIds[0]);
                vm.prank(prevOwner);
                try router.setDepositsDisabled(poolIds[0], cur) {
                    t(false, "SP-41: previous owner could still call setDepositsDisabled");
                } catch {}
                address fr = router.feeRecipient();
                vm.prank(prevOwner);
                try router.setFeeRecipient(fr) {
                    t(false, "SP-41: previous owner could still call setFeeRecipient");
                } catch {}
            }
            t(admin == router.owner(), "SP-41: harness admin out of sync with owner()");
        }
    }

    /// @notice SP-42: no admin dispatch ever touches user value: balances, sampled positions, credits, router NFT count and listed keys unchanged; poolCount non-decreasing
    function property_adminNeverMovesValue() internal {
        _assertBalancesUnchanged("SP-42");
        _assertSamplesUnchanged("SP-42");
        _assertCreditsUnchanged("SP-42");
        gte(router.poolCount(), stateBefore.poolCount, "SP-42: poolCount decreased");
        t(keccak256(abi.encode(router.getPoolKey(poolIds[0]))) == keccak256(abi.encode(poolKeys[0])), "SP-42: pool 0 key changed");
        eq(stateAfter.nftRouter, stateBefore.nftRouter, "SP-42: router NFT count changed by an admin action");
        eq(router.positionCount(), stateBefore.positionCount, "SP-42: positionCount changed by an admin action");
    }

    // ───────────────────────── probes / pool ─────────────────────────

    /// @notice SP-43: an outsider cannot transfer or modify a custodied NFT directly on the PositionManager; ownership and liquidity are unchanged
    function property_directPositionManagerProbe(bool transferOk, bool modifyOk, uint256 tokenId) internal {
        t(!transferOk, "SP-43: outsider transferred a custodied NFT on the PositionManager");
        t(!modifyOk, "SP-43: outsider decreased a custodied position on the PositionManager");
        t(_nftOwner(tokenId) == address(router), "SP-43: NFT left the router");
        eq(uint256(positionManager.getPositionLiquidity(tokenId)), uint256(stateBefore.posPmLiq), "SP-43: v4 liquidity changed");
    }

    /// @notice SP-44: router operations never move any pool's price; active liquidity changes only by the expected delta on the touched pool
    function property_poolStateUntouchedByRouterOps(uint256 pool, int256 liqDelta) internal {
        for (uint256 p; p < POOLS; ++p) {
            eq(uint256(stateAfter.price[p]), uint256(stateBefore.price[p]), "SP-44: pool price moved by a router operation");
            int256 want = p == pool ? liqDelta : int256(0);
            eq(_d(uint256(stateAfter.activeLiq[p]), uint256(stateBefore.activeLiq[p])), want, "SP-44: pool active liquidity delta != expected");
        }
    }

    /// @notice SP-45: fee accrual is local: after a donate/swap on `pool`, sampled open positions elsewhere (and out-of-range ones on a donate) are unchanged, in-pool ones non-decreasing
    function property_feeAccrualLocality(uint256 pool, bool isDonate) internal {
        for (uint256 i; i < stateBefore.sampleCount; ++i) {
            if (stateBefore.sampleClosed[i]) continue;
            bool mustHold = stateBefore.samplePool[i] != pool || (isDonate && !stateBefore.sampleInRange[i]);
            if (mustHold) {
                eq(stateAfter.sampleFees0[i], stateBefore.sampleFees0[i], "SP-45: fees0 of an untouched position changed");
                eq(stateAfter.sampleFees1[i], stateBefore.sampleFees1[i], "SP-45: fees1 of an untouched position changed");
            } else {
                gte(stateAfter.sampleFees0[i], stateBefore.sampleFees0[i], "SP-45: fees0 decreased on the touched pool");
                gte(stateAfter.sampleFees1[i], stateBefore.sampleFees1[i], "SP-45: fees1 decreased on the touched pool");
            }
        }
    }

    // ――――――――――――――――― Specific property helpers ―――――――――――――――――

    uint256 internal constant NONE = type(uint256).max;

    /// @dev Signed difference a - b (both far below 2^255).
    function _d(uint256 a, uint256 b) internal pure returns (int256) {
        return int256(a) - int256(b);
    }

    function _actorIndex(address a) internal view returns (uint256) {
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i] == a) return i;
        }
        return NONE;
    }

    function _recipientIndex(address r) internal view returns (uint256) {
        for (uint256 i; i < recipientsEver.length && i < MAX_RECIPIENTS; ++i) {
            if (recipientsEver[i] == r) return i;
        }
        return NONE;
    }

    function _tokenIndexOrNone(address token) internal view returns (uint256) {
        for (uint256 i; i < TOKENS; ++i) {
            if (address(tokens[i]) == token) return i;
        }
        return NONE;
    }

    /// @dev Token index of a pool's currency0 (`one == false`) or currency1.
    function _poolTok(uint256 pool, bool one) internal view returns (uint256) {
        return _tokenIndex(address(_token(pool, one)));
    }

    /// @dev Handler-local balance picture for the round-trip handlers.
    function _outer(uint256 pool, address who) internal view returns (Outer memory o) {
        o.feeRecipient = router.feeRecipient();
        for (uint256 i; i < 2; ++i) {
            MockERC20 token = _token(pool, i == 1);
            o.actorBal[i] = token.balanceOf(who);
            o.routerBal[i] = token.balanceOf(address(router));
            o.pmBal[i] = token.balanceOf(address(poolManager));
            o.total[i] = router.totalClaimableCommission(address(token));
            o.credit[i] = router.claimableCommission(o.feeRecipient, address(token));
            uint256 sum = token.balanceOf(address(this));
            for (uint256 a; a < actors.length; ++a) {
                sum += token.balanceOf(actors[a]);
            }
            o.sumUsers[i] = sum;
        }
    }

    function _assertBalancesUnchanged(string memory tag) internal {
        for (uint256 tk; tk < TOKENS; ++tk) {
            eq(stateAfter.routerBal[tk], stateBefore.routerBal[tk], string.concat(tag, ": router balance moved"));
            eq(stateAfter.pmBal[tk], stateBefore.pmBal[tk], string.concat(tag, ": poolManager balance moved"));
            eq(stateAfter.harnessBal[tk], stateBefore.harnessBal[tk], string.concat(tag, ": harness balance moved"));
            for (uint256 a; a < actors.length && a < 3; ++a) {
                eq(stateAfter.actorBal[a][tk], stateBefore.actorBal[a][tk], string.concat(tag, ": actor balance moved"));
            }
        }
    }

    function _assertCreditsUnchanged(string memory tag) internal {
        for (uint256 tk; tk < TOKENS; ++tk) {
            eq(stateAfter.totalClaimable[tk], stateBefore.totalClaimable[tk], string.concat(tag, ": totalClaimableCommission changed"));
            for (uint256 r; r < recipientsEver.length && r < MAX_RECIPIENTS; ++r) {
                eq(stateAfter.credit[r][tk], stateBefore.credit[r][tk], string.concat(tag, ": a recipient credit changed"));
            }
        }
    }

    /// @dev positionCount, nextTokenId, depositCount(actors), poolCount and feeRecipient unchanged.
    function _assertCountsUnchanged(string memory tag) internal {
        eq(router.positionCount(), stateBefore.positionCount, string.concat(tag, ": positionCount changed"));
        eq(positionManager.nextTokenId(), stateBefore.nextTokenId, string.concat(tag, ": nextTokenId changed"));
        eq(router.poolCount(), stateBefore.poolCount, string.concat(tag, ": poolCount changed"));
        for (uint256 a; a < actors.length && a < 3; ++a) {
            eq(router.depositCount(actors[a]), stateBefore.depositCount[a], string.concat(tag, ": depositCount changed"));
        }
        t(router.feeRecipient() == stateBefore.feeRecipient, string.concat(tag, ": feeRecipient changed"));
    }

    function _assertAdminUnchanged(string memory tag) internal {
        t(router.feeRecipient() == stateBefore.feeRecipient, string.concat(tag, ": feeRecipient changed"));
        t(router.owner() == stateBefore.owner, string.concat(tag, ": owner changed"));
        t(router.pendingOwner() == stateBefore.pendingOwner, string.concat(tag, ": pendingOwner changed"));
    }

    function _assertFlagsUnchanged(string memory tag) internal {
        for (uint256 p; p < POOLS; ++p) {
            t(router.depositsDisabled(poolIds[p]) == stateBefore.depositsDisabled[p], string.concat(tag, ": depositsDisabled changed"));
            t(router.ejectEnabled(poolIds[p]) == stateBefore.ejectEnabled[p], string.concat(tag, ": ejectEnabled changed"));
        }
    }

    /// @dev The sampled other positions kept their closed flag, NFT owner and v4 liquidity.
    function _assertSamplesUnchanged(string memory tag) internal {
        for (uint256 i; i < stateBefore.sampleCount && i < stateAfter.sampleCount; ++i) {
            if (stateAfter.sampleIds[i] != stateBefore.sampleIds[i]) continue; // tail shifted by a new open
            t(stateAfter.sampleClosed[i] == stateBefore.sampleClosed[i], string.concat(tag, ": another position's closed flag changed"));
            t(stateAfter.sampleNftOwner[i] == stateBefore.sampleNftOwner[i], string.concat(tag, ": another position's NFT owner changed"));
            eq(uint256(stateAfter.samplePmLiq[i]), uint256(stateBefore.samplePmLiq[i]), string.concat(tag, ": another position's v4 liquidity changed"));
        }
    }

    /// @dev The nine immutable DepositRecord fields of `now` equal those of `was` (a view read before the call).
    function _assertImmutableFields(
        ValariRouterV3.PositionView memory now_,
        ValariRouterV3.PositionView memory was,
        string memory tag
    ) internal {
        t(
            now_.poolId == was.poolId && now_.depositor == was.depositor && now_.owner == was.owner
                && now_.openedAt == was.openedAt && now_.tickLower == was.tickLower && now_.tickUpper == was.tickUpper
                && now_.initialLiquidity == was.initialLiquidity && now_.amount0Deposited == was.amount0Deposited
                && now_.amount1Deposited == was.amount1Deposited,
            string.concat(tag, ": an immutable record field changed")
        );
        t(now_.depositor == depositorOf[now_.tokenId] && now_.poolId == poolIds[poolIndexOf[now_.tokenId]], string.concat(tag, ": record disagrees with harness bookkeeping"));
    }

    /// @dev Human-readable name of a revert reason's selector, for assertion messages.
    function _reasonName(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) return "empty revert data";
        bytes4 s = _selector(reason);
        if (s == ValariRouterV3.InvalidConfiguration.selector) return "InvalidConfiguration";
        if (s == ValariRouterV3.InvalidPool.selector) return "InvalidPool";
        if (s == ValariRouterV3.DuplicatePool.selector) return "DuplicatePool";
        if (s == ValariRouterV3.InvalidRange.selector) return "InvalidRange";
        if (s == ValariRouterV3.InvalidLiquidity.selector) return "InvalidLiquidity";
        if (s == ValariRouterV3.InvalidPriceBounds.selector) return "InvalidPriceBounds";
        if (s == ValariRouterV3.PriceOutOfBounds.selector) return "PriceOutOfBounds";
        if (s == ValariRouterV3.LiquidityBelowMinimum.selector) return "LiquidityBelowMinimum";
        if (s == ValariRouterV3.DeadlineExpired.selector) return "DeadlineExpired";
        if (s == ValariRouterV3.UnsupportedToken.selector) return "UnsupportedToken";
        if (s == ValariRouterV3.UnexpectedPosition.selector) return "UnexpectedPosition";
        if (s == ValariRouterV3.UnknownPosition.selector) return "UnknownPosition";
        if (s == ValariRouterV3.InvalidPageSize.selector) return "InvalidPageSize";
        if (s == ValariRouterV3.InvalidOwner.selector) return "InvalidOwner";
        if (s == ValariRouterV3.InvalidFeeRecipient.selector) return "InvalidFeeRecipient";
        if (s == ValariRouterV3.InvalidRecipient.selector) return "InvalidRecipient";
        if (s == ValariRouterV3.DepositsDisabled.selector) return "DepositsDisabled";
        if (s == ValariRouterV3.EjectDisabled.selector) return "EjectDisabled";
        if (s == ValariRouterV3.NotPositionOwner.selector) return "NotPositionOwner";
        if (s == ValariRouterV3.PositionClosed.selector) return "PositionClosed";
        if (s == ValariRouterV3.InsufficientProceeds.selector) return "InsufficientProceeds";
        if (s == ValariRouterV3.InvalidCommissionWithdrawal.selector) return "InvalidCommissionWithdrawal";
        if (s == ValariRouterV3.InsufficientCommission.selector) return "InsufficientCommission";
        if (s == bytes4(0x08c379a0)) return "Error(string)";
        if (s == bytes4(0x4e487b71)) return "Panic";
        return "unknown selector";
    }
}
