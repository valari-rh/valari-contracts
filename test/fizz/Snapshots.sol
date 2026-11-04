// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {Base} from "./Base.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ValariRouterV3} from "../../src/ValariRouterV3.sol";

/// @notice Used to take snapshots of the state before and after a function call.
/// @dev Snapshots are parameterised: a handler stores `snapshotPool` (pool index),
///      `snapshotTokenId` (0 = no target position) and `snapshotPayee` (the `to` / payee, or the
///      acting user) in storage BEFORE calling `snapshotBefore()`. Every read is guarded so
///      `_takeSnapshot` never reverts: `getPosition` goes through try/catch, `_nftOwner` swallows
///      the ERC721 revert on a burned id, and `getPositionLiquidity` on a burned id returns 0.
abstract contract Snapshots is Base {
    uint256 internal constant SAMPLE = 8;
    uint256 internal constant MAX_RECIPIENTS = 4;

    struct State {
        // ── counters
        uint256 positionCount;
        uint256 poolCount;
        uint256 nextTokenId;
        uint256[3] depositCount; // actor index
        uint256[TOKENS] stockPoolCount; // token index
        // ── admin
        address feeRecipient;
        address owner;
        address pendingOwner;
        bool[POOLS] depositsDisabled; // pool index
        bool[POOLS] ejectEnabled; // pool index
        // ── pools
        uint160[POOLS] price;
        uint128[POOLS] activeLiq;
        // ── token balances (token index)
        uint256[TOKENS] routerBal;
        uint256[TOKENS] pmBal;
        uint256[TOKENS] harnessBal;
        uint256[TOKENS] totalClaimable;
        uint256[TOKENS][3] actorBal; // actorBal[actor][token]
        uint256[TOKENS] payeeBal; // snapshotPayee
        uint256[TOKENS] depositorBal; // depositorOf[snapshotTokenId]
        uint256[TOKENS][MAX_RECIPIENTS] credit; // credit[recipientsEver index][token]
        uint256[TOKENS] sumUsersBal; // actors + harness (= actors ∪ recipientsEver)
        // ── NFT custody
        uint256 nftRouter;
        uint256 nftPayee;
        // ── target position (snapshotTokenId)
        bool posKnown; // getPosition did not revert
        bool posClosed;
        address posNftOwner;
        uint128 posPmLiq;
        uint256 posFeesCollected0;
        uint256 posFeesCollected1;
        uint256 posCommissionAccrued0;
        uint256 posCommissionAccrued1;
        uint256 viewAmount0;
        uint256 viewAmount1;
        uint256 viewFees0;
        uint256 viewFees1;
        uint256 viewCommission0;
        uint256 viewCommission1;
        uint256 viewNetFees0;
        uint256 viewNetFees1;
        uint128 viewLiquidity;
        uint128 viewInitialLiquidity;
        bool viewInRange;
        uint160 viewSqrtPrice;
        int24 viewTickLower;
        int24 viewTickUpper;
        // ── sampled tail of other positions (newest first, skipping snapshotTokenId)
        uint256[SAMPLE] sampleIds;
        bool[SAMPLE] sampleClosed;
        address[SAMPLE] sampleNftOwner;
        uint128[SAMPLE] samplePmLiq;
        uint256[SAMPLE] sampleFees0;
        uint256[SAMPLE] sampleFees1;
        bool[SAMPLE] sampleInRange;
        uint256[SAMPLE] samplePool;
        uint256 sampleCount;
    }

    State internal stateBefore;
    State internal stateAfter;

    /// @dev Snapshot parameters; set by the handler before `snapshotBefore()`.
    uint256 internal snapshotPool;
    uint256 internal snapshotTokenId;
    address internal snapshotPayee;

    function snapshotBefore() internal {
        _takeSnapshot(stateBefore);
    }

    function snapshotAfter() internal {
        _takeSnapshot(stateAfter);
    }

    /// @dev Convenience setter so handlers do not have to touch the three parameters by hand.
    function _setSnapshotTarget(uint256 pool, uint256 tokenId, address payee) internal {
        snapshotPool = pool;
        snapshotTokenId = tokenId;
        snapshotPayee = payee;
    }

    function _takeSnapshot(State storage state) private {
        _snapCounters(state);
        _snapAdmin(state);
        _snapPools(state);
        _snapBalances(state);
        _snapNft(state);
        _snapTarget(state);
        _snapSamples(state);
    }

    function _snapCounters(State storage state) private {
        state.positionCount = router.positionCount();
        state.poolCount = router.poolCount();
        state.nextTokenId = positionManager.nextTokenId();
        for (uint256 a; a < actors.length && a < 3; ++a) {
            state.depositCount[a] = router.depositCount(actors[a]);
        }
        for (uint256 t; t < TOKENS; ++t) {
            state.stockPoolCount[t] = router.stockPoolCount(address(tokens[t]));
        }
    }

    function _snapAdmin(State storage state) private {
        state.feeRecipient = router.feeRecipient();
        state.owner = router.owner();
        state.pendingOwner = router.pendingOwner();
        for (uint256 p; p < POOLS; ++p) {
            state.depositsDisabled[p] = router.depositsDisabled(poolIds[p]);
            state.ejectEnabled[p] = router.ejectEnabled(poolIds[p]);
        }
    }

    function _snapPools(State storage state) private {
        for (uint256 p; p < POOLS; ++p) {
            state.price[p] = _price(p);
            state.activeLiq[p] = stateView.getLiquidity(PoolId.wrap(poolIds[p]));
        }
    }

    function _snapBalances(State storage state) private {
        address depositor = snapshotTokenId != 0 ? depositorOf[snapshotTokenId] : address(0);
        for (uint256 t; t < TOKENS; ++t) {
            MockERC20 token = tokens[t];
            state.routerBal[t] = token.balanceOf(address(router));
            state.pmBal[t] = token.balanceOf(address(poolManager));
            state.harnessBal[t] = token.balanceOf(address(this));
            state.totalClaimable[t] = router.totalClaimableCommission(address(token));
            uint256 sum = state.harnessBal[t];
            for (uint256 a; a < actors.length && a < 3; ++a) {
                state.actorBal[a][t] = token.balanceOf(actors[a]);
                sum += state.actorBal[a][t];
            }
            state.sumUsersBal[t] = sum;
            state.payeeBal[t] = snapshotPayee != address(0) ? token.balanceOf(snapshotPayee) : 0;
            state.depositorBal[t] = depositor != address(0) ? token.balanceOf(depositor) : 0;
            for (uint256 r; r < MAX_RECIPIENTS; ++r) {
                state.credit[r][t] = r < recipientsEver.length
                    ? router.claimableCommission(recipientsEver[r], address(token))
                    : 0;
            }
        }
    }

    function _snapNft(State storage state) private {
        IERC721 nft = IERC721(address(positionManager));
        state.nftRouter = nft.balanceOf(address(router));
        state.nftPayee = snapshotPayee != address(0) ? nft.balanceOf(snapshotPayee) : 0;
    }

    function _snapTarget(State storage state) private {
        uint256 id = snapshotTokenId;
        state.posKnown = false;
        state.posClosed = false;
        state.posNftOwner = address(0);
        state.posPmLiq = 0;
        state.posFeesCollected0 = 0;
        state.posFeesCollected1 = 0;
        state.posCommissionAccrued0 = 0;
        state.posCommissionAccrued1 = 0;
        state.viewAmount0 = 0;
        state.viewAmount1 = 0;
        state.viewFees0 = 0;
        state.viewFees1 = 0;
        state.viewCommission0 = 0;
        state.viewCommission1 = 0;
        state.viewNetFees0 = 0;
        state.viewNetFees1 = 0;
        state.viewLiquidity = 0;
        state.viewInitialLiquidity = 0;
        state.viewInRange = false;
        state.viewSqrtPrice = 0;
        state.viewTickLower = 0;
        state.viewTickUpper = 0;
        if (id == 0) return;

        state.posNftOwner = _nftOwner(id);
        state.posPmLiq = positionManager.getPositionLiquidity(id);
        try router.getPosition(id) returns (ValariRouterV3.PositionView memory v) {
            state.posKnown = true;
            state.posClosed = v.closed;
            state.posFeesCollected0 = v.feesCollected0;
            state.posFeesCollected1 = v.feesCollected1;
            state.posCommissionAccrued0 = v.commissionAccrued0;
            state.posCommissionAccrued1 = v.commissionAccrued1;
            state.viewAmount0 = v.amount0;
            state.viewAmount1 = v.amount1;
            state.viewFees0 = v.fees0;
            state.viewFees1 = v.fees1;
            state.viewCommission0 = v.commission0;
            state.viewCommission1 = v.commission1;
            state.viewNetFees0 = v.netFees0;
            state.viewNetFees1 = v.netFees1;
            state.viewLiquidity = v.liquidity;
            state.viewInitialLiquidity = v.initialLiquidity;
            state.viewInRange = v.inRange;
            state.viewSqrtPrice = v.sqrtPriceX96;
            state.viewTickLower = v.tickLower;
            state.viewTickUpper = v.tickUpper;
        } catch {}
    }

    /// @dev Up to SAMPLE of the newest harness positions other than the target, with the fields
    ///      the "nothing else changed" properties compare.
    function _snapSamples(State storage state) private {
        uint256 count;
        uint256 n = positionIds.length;
        for (uint256 i = n; i > 0 && count < SAMPLE; --i) {
            uint256 id = positionIds[i - 1];
            if (id == snapshotTokenId) continue;
            state.sampleIds[count] = id;
            state.samplePool[count] = poolIndexOf[id];
            state.sampleNftOwner[count] = _nftOwner(id);
            state.samplePmLiq[count] = positionManager.getPositionLiquidity(id);
            state.sampleClosed[count] = false;
            state.sampleFees0[count] = 0;
            state.sampleFees1[count] = 0;
            state.sampleInRange[count] = false;
            try router.getPosition(id) returns (ValariRouterV3.PositionView memory v) {
                state.sampleClosed[count] = v.closed;
                state.sampleFees0[count] = v.fees0;
                state.sampleFees1[count] = v.fees1;
                state.sampleInRange[count] = v.inRange;
            } catch {}
            ++count;
        }
        state.sampleCount = count;
    }
}
