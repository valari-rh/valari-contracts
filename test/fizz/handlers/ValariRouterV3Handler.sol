// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @notice Handles the interaction with ValariRouterV3
/// @dev Clamped handlers prepare realistic inputs (valid pool, a live quote, a position the
///      acting user owns) and forward into the unclamped raw-call layer. Unclamped handlers are
///      also fuzzer entry points on their own, with the *current* actor as caller, so access
///      control (non-depositor collect/exit/eject, non-owner admin calls) is exercised for free.
///
///      Wiring: every unclamped handler sets the snapshot target, takes `snapshotBefore()`, makes
///      the raw call under try/catch, takes `snapshotAfter()`, feeds the ghosts on success and
///      runs the specific properties for both branches. Clamped handlers add the properties that
///      need the inputs they prepared (quote, flags, bounds). Payees of the `*To` variants and of
///      `withdrawCommission` are mapped onto known actors (0 / router are kept so the router's own
///      recipient guards stay reachable) because the global supply/ledger properties rely on a
///      closed holder set.
abstract contract ValariRouterV3Handler is Properties {
    uint128 internal constant MAX_BUDGET = 100 ether;
    uint256 internal constant MAX_SWAP = 80 ether;
    uint256 internal constant MAX_DONATE = 1 ether;
    uint256 internal constant MAX_CYCLES = 5;

    /// @dev Pre-call facts about the target of a position handler.
    struct Pre {
        bool known; // getPosition did not revert
        bool wasClosed;
        bool custodied; // _nftOwner(id) == router
        uint256 pool;
        ValariRouterV3.PositionView v; // view read immediately before the call
    }

    /// @dev Result of an admin dispatch that the dispatcher asserts on.
    struct AdminResult {
        bool ok;
        bytes reason;
        bytes32 id; // addPool
        uint256 pool; // addPool
        bool dupOk; // addPool: a second listing of the same key
        bytes dupReason;
        address prev; // acceptOwnership: previous owner
        address pending; // acceptOwnership: pending owner that accepted
    }

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Quote-then-open on a listed pool with budgets bounded by the actor's balances.
    ///         minLiquidity is the live quote less `slippageBps`; price bounds are the quoted
    ///         price widened by `boundBps` on each side (0 = exact, as the fixtures do).
    function valariRouterV3_openPosition_clamped(
        uint256 poolSeed,
        uint128 amount0Max,
        uint128 amount1Max,
        uint8 rangeSeed,
        uint256 slippageBps,
        uint256 boundBps,
        uint256 deadline
    ) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = _clampBudget(pool, false, amount0Max);
        amount1Max = _clampBudget(pool, true, amount1Max);
        slippageBps = clampBetween(slippageBps, 0, 5_000);
        boundBps = clampBetween(boundBps, 0, 1_000);
        deadline = block.timestamp + clampBetween(deadline, 0, 1 days);

        (bool quoted,, ValariRouterV3.DepositQuote memory quote) =
            _tryPreview(pool, amount0Max, amount1Max, lower, upper);
        if (!quoted) return; // zero quote (e.g. a budget of 0 on the side the range needs)
        uint128 minLiquidity = uint128(uint256(quote.liquidity) * (10_000 - slippageBps) / 10_000);
        if (minLiquidity == 0) minLiquidity = 1;
        (uint160 lo, uint160 hi) = _bounds(quote.sqrtPriceX96, boundBps);

        bool wasDisabled = router.depositsDisabled(poolIds[pool]);
        (bool ok, bytes memory reason, OpenResult memory r) = valariRouterV3_openPosition(
            poolIds[pool], amount0Max, amount1Max, lower, upper, minLiquidity, lo, hi, deadline
        );
        property_openGate(ok, reason, pool, wasDisabled);
        property_depositLiveness(ok, reason, wasDisabled);
        if (ok) {
            property_openMatchesQuote(r, quote);
            property_boundaryPriceRounding(true, pool, lower, upper, r.amount0, r.amount1, quote.amount0, quote.amount1);
        }
    }

    /// @notice Near-zero stress: budgets of 1..1e6 raw units, where v4 liquidity math truncates.
    function valariRouterV3_openPosition_smallBudget(
        uint256 poolSeed,
        uint128 amount0Max,
        uint128 amount1Max,
        uint8 rangeSeed
    ) public {
        amount0Max = uint128(clampBetween(amount0Max, 1, 1e6));
        amount1Max = uint128(clampBetween(amount1Max, 1, 1e6));
        valariRouterV3_openPosition_clamped(poolSeed, amount0Max, amount1Max, rangeSeed, 0, 0, 0);
    }

    /// @notice Full-amount stress: spend the actor's entire balance of both pool tokens.
    function valariRouterV3_openPosition_fullBalance(uint256 poolSeed, uint8 rangeSeed) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        uint256 b0 = _token(pool, false).balanceOf(actor);
        uint256 b1 = _token(pool, true).balanceOf(actor);
        if (b0 == 0 || b1 == 0) return;
        uint128 budget0 = b0 > type(uint128).max ? type(uint128).max : uint128(b0);
        uint128 budget1 = b1 > type(uint128).max ? type(uint128).max : uint128(b1);
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        (bool quoted,, ValariRouterV3.DepositQuote memory quote) = _tryPreview(pool, budget0, budget1, lower, upper);
        if (!quoted) return;
        bool wasDisabled = router.depositsDisabled(poolIds[pool]);
        (bool ok, bytes memory reason, OpenResult memory r) = valariRouterV3_openPosition(
            poolIds[pool],
            budget0,
            budget1,
            lower,
            upper,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        property_openGate(ok, reason, pool, wasDisabled);
        property_depositLiveness(ok, reason, wasDisabled);
        if (ok) {
            property_openMatchesQuote(r, quote);
            property_boundaryPriceRounding(true, pool, lower, upper, r.amount0, r.amount1, quote.amount0, quote.amount1);
        }
    }

    /// @notice Quote, move the pool price with a swap, then open with the stale quote. Exercises
    ///         PriceOutOfBounds / LiquidityBelowMinimum and the "bounds wide enough" acceptance.
    function valariRouterV3_openPosition_afterPriceMove(
        uint256 poolSeed,
        uint128 amount0Max,
        uint128 amount1Max,
        uint8 rangeSeed,
        bool zeroForOne,
        uint128 swapAmount,
        uint256 boundBps
    ) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = _clampBudget(pool, false, amount0Max);
        amount1Max = _clampBudget(pool, true, amount1Max);
        boundBps = clampBetween(boundBps, 0, 2_000);
        (bool quoted,, ValariRouterV3.DepositQuote memory quote) =
            _tryPreview(pool, amount0Max, amount1Max, lower, upper);
        if (!quoted) return;
        // A swap revert (no active liquidity, price limit) is a legitimate v4 outcome; a property
        // failure inside pool_swap is not and is re-thrown.
        try this.pool_swap(pool, zeroForOne, swapAmount) {} catch (bytes memory r) { _rethrowAssert(r); }
        uint160 live = _price(pool);
        (uint160 lo, uint160 hi) = _bounds(quote.sqrtPriceX96, boundBps);
        // The unclamped layer snapshots after the swap and before the open, and keeps the swap's
        // state when the stale-quote open is rejected.
        (bool ok, bytes memory reason, OpenResult memory r) = valariRouterV3_openPosition(
            poolIds[pool], amount0Max, amount1Max, lower, upper, quote.liquidity, lo, hi, block.timestamp
        );
        property_staleQuoteOpen(ok, reason, r, quote, live, lo, hi);
    }

    /// @notice Price bounds that exclude the live price by exactly one unit (above or below).
    function valariRouterV3_openPosition_outsideBounds(
        uint256 poolSeed,
        uint128 amount0Max,
        uint128 amount1Max,
        uint8 rangeSeed,
        bool above
    ) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = _clampBudget(pool, false, amount0Max);
        amount1Max = _clampBudget(pool, true, amount1Max);
        (bool quoted,, ValariRouterV3.DepositQuote memory quote) =
            _tryPreview(pool, amount0Max, amount1Max, lower, upper);
        if (!quoted) return;
        uint160 p = quote.sqrtPriceX96;
        (uint160 lo, uint160 hi) = above ? (p + 1, type(uint160).max) : (uint160(1), p - 1);
        (bool ok, bytes memory reason,) = valariRouterV3_openPosition(
            poolIds[pool], amount0Max, amount1Max, lower, upper, quote.liquidity, lo, hi, block.timestamp
        );
        property_outsideBoundsReverts(ok, reason, poolIds[pool]);
    }

    /// @notice Zero-input guards of openPosition: minLiquidity == 0, or sqrtPriceMinX96 == 0.
    function valariRouterV3_openPosition_zeroGuards(
        uint256 poolSeed,
        uint128 amount0Max,
        uint128 amount1Max,
        uint8 rangeSeed,
        bool priceGuard
    ) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = _clampBudget(pool, false, amount0Max);
        amount1Max = _clampBudget(pool, true, amount1Max);
        (bool quoted,, ValariRouterV3.DepositQuote memory quote) =
            _tryPreview(pool, amount0Max, amount1Max, lower, upper);
        if (!quoted) return;
        bool ok;
        bytes memory reason;
        if (priceGuard) {
            (ok, reason,) = valariRouterV3_openPosition(
                poolIds[pool], amount0Max, amount1Max, lower, upper, quote.liquidity, 0, quote.sqrtPriceX96, block.timestamp
            );
        } else {
            (ok, reason,) = valariRouterV3_openPosition(
                poolIds[pool], amount0Max, amount1Max, lower, upper, 0, quote.sqrtPriceX96, quote.sqrtPriceX96, block.timestamp
            );
        }
        property_zeroInputGuards(priceGuard ? 3 : 2, ok, reason);
    }

    /// @notice previewDeposit with both budgets zero, and with zero on the side the range needs.
    function valariRouterV3_previewDeposit_zero(uint256 poolSeed, uint8 rangeSeed) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        (bool ok, bytes memory reason,) = _tryPreview(pool, 0, 0, lower, upper);
        property_zeroInputGuards(0, ok, reason);
        // At/above the range only currency1 is needed; otherwise currency0 is needed (or both).
        bool needsOnlyOne = _price(pool) >= TickMath.getSqrtPriceAtTick(upper);
        (uint128 b0, uint128 b1) = needsOnlyOne ? (uint128(1e18), uint128(0)) : (uint128(0), uint128(1e18));
        (ok, reason,) = _tryPreview(pool, b0, b1, lower, upper);
        property_zeroInputGuards(1, ok, reason);
    }

    /// @notice previewDeposit is monotone in the budgets.
    function valariRouterV3_previewDeposit_monotone(
        uint256 poolSeed,
        uint128 amount0Max,
        uint128 amount1Max,
        uint128 extra0,
        uint128 extra1,
        uint8 rangeSeed
    ) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = uint128(clampBetween(amount0Max, 0, MAX_BUDGET));
        amount1Max = uint128(clampBetween(amount1Max, 0, MAX_BUDGET));
        extra0 = uint128(clampBetween(extra0, 0, MAX_BUDGET));
        extra1 = uint128(clampBetween(extra1, 0, MAX_BUDGET));
        (bool ok,, ValariRouterV3.DepositQuote memory q) = _tryPreview(pool, amount0Max, amount1Max, lower, upper);
        if (!ok) return;
        (bool ok2,, ValariRouterV3.DepositQuote memory q2) =
            _tryPreview(pool, amount0Max + extra0, amount1Max + extra1, lower, upper);
        if (!ok2) return; // only the int128 cap can reject a larger budget here; SP-12 covers false rejects
        property_previewMonotone(q, q2, amount0Max, amount1Max);
    }

    /// @notice previewDeposit never rejects a budget the liquidity math itself accepts.
    function valariRouterV3_previewDeposit_noFalseReject(
        uint256 poolSeed,
        uint128 amount0Max,
        uint128 amount1Max,
        uint8 rangeSeed
    ) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = uint128(clampBetween(amount0Max, 0, 1e27));
        amount1Max = uint128(clampBetween(amount1Max, 0, 1e27));
        uint128 expected = LiquidityAmounts.getLiquidityForAmounts(
            _price(pool),
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount0Max,
            amount1Max
        );
        (bool ok, bytes memory reason, ValariRouterV3.DepositQuote memory q) =
            _tryPreview(pool, amount0Max, amount1Max, lower, upper);
        property_previewNoFalseReject(ok, reason, expected, q.liquidity);
    }

    /// @notice Collect as the recorded depositor of a known position.
    function valariRouterV3_collectFees_clamped(uint256 idSeed, uint256 deadline) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        deadline = block.timestamp + clampBetween(deadline, 0, 1 days);
        address prev = actor;
        actor = depositorOf[tokenId];
        valariRouterV3_collectFees(tokenId, deadline);
        actor = prev;
    }

    /// @notice Collect as the depositor, paid to another known actor.
    function valariRouterV3_collectFeesTo_clamped(uint256 idSeed, address to, uint256 deadline) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        to = toActor(to);
        deadline = block.timestamp + clampBetween(deadline, 0, 1 days);
        address prev = actor;
        actor = depositorOf[tokenId];
        valariRouterV3_collectFeesTo(tokenId, to, deadline);
        actor = prev;
    }

    /// @notice Two consecutive collections with no pool activity in between: the second one must
    ///         realize nothing (no double payment of the same fees).
    function valariRouterV3_collectFees_twice(uint256 idSeed) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        address prev = actor;
        actor = depositorOf[tokenId];
        valariRouterV3_collectFees(tokenId, block.timestamp);
        (bool ok2,, ValariRouterV3.Payout memory p2) = valariRouterV3_collectFees(tokenId, block.timestamp);
        actor = prev;
        if (ok2) property_collectTwiceIdempotent(tokenId, p2);
    }

    /// @notice Collect then exit (mins 0) in the same transaction: the exit must realize no fees.
    function valariRouterV3_collectThenExit(uint256 idSeed) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        address prev = actor;
        actor = depositorOf[tokenId];
        valariRouterV3_collectFees(tokenId, block.timestamp);
        (bool ok,, ValariRouterV3.Payout memory p) = valariRouterV3_exitPosition(tokenId, 0, 0, block.timestamp);
        actor = prev;
        if (ok) property_collectThenExitNoFees(p);
    }

    /// @notice Exit as the depositor with principal minimums derived from the live view and
    ///         scaled down by `slippageBps` (0 = exact principal, which must still succeed).
    function valariRouterV3_exitPosition_clamped(uint256 idSeed, uint256 slippageBps, uint256 deadline)
        public
    {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        (uint128 min0, uint128 min1) = _exitMinimums(tokenId, slippageBps);
        deadline = block.timestamp + clampBetween(deadline, 0, 1 days);
        address prev = actor;
        actor = depositorOf[tokenId];
        valariRouterV3_exitPosition(tokenId, min0, min1, deadline);
        actor = prev;
    }

    /// @notice Exit as the depositor, paid to another known actor.
    function valariRouterV3_exitPositionTo_clamped(
        uint256 idSeed,
        address to,
        uint256 slippageBps,
        uint256 deadline
    ) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        to = toActor(to);
        (uint128 min0, uint128 min1) = _exitMinimums(tokenId, slippageBps);
        deadline = block.timestamp + clampBetween(deadline, 0, 1 days);
        address prev = actor;
        actor = depositorOf[tokenId];
        valariRouterV3_exitPositionTo(tokenId, to, min0, min1, deadline);
        actor = prev;
    }

    /// @notice Exit with minimums one unit above the live principal: must revert atomically.
    function valariRouterV3_exitPosition_minTooHigh(uint256 idSeed, bool side0) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        ValariRouterV3.PositionView memory p = router.getPosition(tokenId);
        uint128 min0 = side0 ? uint128(p.amount0) + 1 : 0;
        uint128 min1 = side0 ? 0 : uint128(p.amount1) + 1;
        address prev = actor;
        actor = depositorOf[tokenId];
        (bool ok, bytes memory reason,) = valariRouterV3_exitPosition(tokenId, min0, min1, block.timestamp);
        actor = prev;
        property_failedExitNoop(ok, reason, tokenId);
    }

    /// @notice Eject as the depositor to a known actor (only succeeds where the owner enabled it).
    function valariRouterV3_ejectPosition_clamped(uint256 idSeed, address to) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        to = toActor(to);
        address prev = actor;
        actor = depositorOf[tokenId];
        valariRouterV3_ejectPosition(tokenId, to);
        actor = prev;
    }

    /// @notice Withdraw part of the acting credit holder's commission in a pool token.
    function valariRouterV3_withdrawCommission_clamped(uint256 tokenSeed, address to, uint256 amount) public {
        address token = address(tokens[tokenSeed % TOKENS]);
        uint256 credit = router.claimableCommission(actor, token);
        if (credit == 0) return;
        amount = clampBetween(amount, 1, credit);
        to = toActor(to);
        valariRouterV3_withdrawCommission(token, to, amount);
    }

    /// @notice Full-amount stress: withdraw the entire credit.
    function valariRouterV3_withdrawCommission_full(uint256 tokenSeed, address to) public {
        address token = address(tokens[tokenSeed % TOKENS]);
        uint256 credit = router.claimableCommission(actor, token);
        if (credit == 0) return;
        (bool ok, bytes memory reason) = valariRouterV3_withdrawCommission(token, toActor(to), credit);
        property_fullWithdrawLiveness(ok, reason, actor, token, credit);
    }

    /// @notice Withdraw one unit more than the credit: must revert.
    function valariRouterV3_withdrawCommission_overdraw(uint256 tokenSeed, address to) public {
        address token = address(tokens[tokenSeed % TOKENS]);
        uint256 credit = router.claimableCommission(actor, token);
        // SP-37 (success => amount <= credit, overdraw => InsufficientCommission) runs inside.
        valariRouterV3_withdrawCommission(token, toActor(to), credit + 1);
    }

    /// @notice The contract owner (or, failing that, any actor) with zero credit withdraws 1: must revert.
    function valariRouterV3_probe_ownerWithdraw(uint256 tokenSeed) public {
        address token = address(tokens[tokenSeed % TOKENS]);
        address caller = router.owner();
        if (router.claimableCommission(caller, token) != 0) {
            caller = address(0);
            for (uint256 i; i < actors.length; ++i) {
                if (router.claimableCommission(actors[i], token) == 0) {
                    caller = actors[i];
                    break;
                }
            }
            if (caller == address(0)) return;
        }
        _setSnapshotTarget(0, 0, caller);
        snapshotBefore();
        bool ok;
        bytes memory reason;
        vm.prank(caller);
        try router.withdrawCommission(token, caller, 1) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        snapshotAfter();
        property_overdrawReverts(ok, reason, caller, token, caller, 1, 0);
    }

    /// @notice Direct ERC-20 donation to the router (dust it can never pay out).
    function valariRouterV3_donateERC20(uint256 tokenSeed, uint256 amount) public {
        uint256 t = tokenSeed % TOKENS;
        uint256 balance = tokens[t].balanceOf(actor);
        if (balance == 0) return;
        amount = clampBetween(amount, 1, balance > 1e18 ? 1e18 : balance);
        _setSnapshotTarget(0, 0, actor);
        snapshotBefore();
        vm.prank(actor);
        tokens[t].transfer(address(router), amount);
        snapshotAfter();
        seededDust[t] += amount;
        ghosts.userDonated[t] += amount;
        property_poolStateUntouchedByRouterOps(0, 0);
    }

    /// @notice Swap on a pool with the harness's own tokens; moves price and accrues LP fees.
    ///         A revert (no active liquidity, price limit) is a legitimate v4 outcome.
    function pool_swap(uint256 poolSeed, bool zeroForOne, uint128 amount) public {
        uint256 pool = toPool(poolSeed);
        uint256 amountIn = 1 + uint256(amount) % MAX_SWAP;
        _setSnapshotTarget(pool, 0, actor);
        snapshotBefore();
        _swap(pool, zeroForOne, amountIn); // a revert unwinds the ghost and skips the assertions
        snapshotAfter();
        _recordSwapFeeCap(pool, zeroForOne, amountIn);
        property_feeAccrualLocality(pool, false);
    }

    /// @notice Donate fees straight to in-range liquidity of a pool.
    function pool_donate(uint256 poolSeed, uint128 amount0, uint128 amount1) public {
        uint256 pool = toPool(poolSeed);
        uint256 a0 = uint256(amount0) % MAX_DONATE;
        uint256 a1 = uint256(amount1) % MAX_DONATE;
        _setSnapshotTarget(pool, 0, actor);
        snapshotBefore();
        _donate(pool, a0, a1);
        snapshotAfter();
        ghosts.donated[_poolTok(pool, false)] += a0;
        ghosts.donated[_poolTok(pool, true)] += a1;
        property_feeAccrualLocality(pool, true);
    }

    /// @notice Owner-only configuration, grouped so it is called less often than user flows.
    function valariRouterV3_secondary(uint8 selector, uint256 arg0, uint256 arg1, address arg2) public {
        selector = uint8(selector % 6);
        _setSnapshotTarget(0, 0, actor);
        snapshotBefore();
        if (selector == 0) {
            AdminResult memory a = _valariRouterV3_acceptOwnership();
            snapshotAfter();
            if (a.ok) {
                ghosts.expectedPendingOwner = address(0);
                property_ownable2Step(false, a.pending, a.prev);
            }
        } else if (selector == 1) {
            AdminResult memory a = _valariRouterV3_addPool(arg0);
            snapshotAfter();
            if (a.ok) {
                listed[a.pool] = true;
                ghosts.listOrder.push(a.pool);
                property_addPoolPostconditions(a.id, a.pool, a.dupOk, a.dupReason);
            }
        } else if (selector == 2) {
            uint256 pool = toPool(arg0);
            bool x = arg1 % 2 == 1;
            bool wasListed = listed[pool];
            AdminResult memory a = _valariRouterV3_setDepositsDisabled(poolIds[pool], x);
            snapshotAfter();
            if (a.ok) ghosts.lastDepositsDisabled[pool] = x;
            property_flagSettersPure(a.ok, a.reason, pool, true, x, wasListed);
        } else if (selector == 3) {
            uint256 pool = toPool(arg0);
            bool x = arg1 % 2 == 1;
            bool wasListed = listed[pool];
            AdminResult memory a = _valariRouterV3_setEjectEnabled(poolIds[pool], x);
            snapshotAfter();
            if (a.ok) ghosts.lastEjectEnabled[pool] = x;
            property_flagSettersPure(a.ok, a.reason, pool, false, x, wasListed);
        } else if (selector == 4) {
            address n = toActor(arg2);
            _valariRouterV3_setFeeRecipient(n);
            snapshotAfter();
            ghosts.expectedFeeRecipient = n;
            property_setFeeRecipientFutureOnly(n);
        } else {
            address n = toActor(arg2);
            _valariRouterV3_transferOwnership(n);
            snapshotAfter();
            ghosts.expectedPendingOwner = n;
            property_ownable2Step(true, n, stateBefore.owner);
        }
        property_adminNeverMovesValue();
        property_poolStateUntouchedByRouterOps(0, 0);
    }

    /// @notice The same owner-only functions called by a plain actor: every one must revert.
    function valariRouterV3_unauthorizedAdmin(uint8 selector, uint256 arg0, address arg2) public {
        selector = uint8(selector % 5);
        // Ownership may have been handed to an actor via the dispatcher; the "unauthorized"
        // caller must be an actor that is not the current owner.
        address caller = actor;
        for (uint256 i; i < actors.length && caller == router.owner(); ++i) {
            caller = actors[(uint256(uint160(actor)) + i + 1) % actors.length];
        }
        if (caller == router.owner()) return;
        vm.prank(caller);
        if (selector == 0) {
            try router.addPool(poolKeys[1 + arg0 % 2]) { t(false, "non-owner addPool succeeded"); } catch {}
        } else if (selector == 1) {
            try router.setDepositsDisabled(poolIds[toPool(arg0)], true) { t(false, "non-owner setDepositsDisabled succeeded"); } catch {}
        } else if (selector == 2) {
            try router.setEjectEnabled(poolIds[toPool(arg0)], true) { t(false, "non-owner setEjectEnabled succeeded"); } catch {}
        } else if (selector == 3) {
            try router.setFeeRecipient(toActor(arg2)) { t(false, "non-owner setFeeRecipient succeeded"); } catch {}
        } else {
            try router.transferOwnership(toActor(arg2)) { t(false, "non-owner transferOwnership succeeded"); } catch {}
        }
    }

    /// @notice The contract owner acts on an open position it did not open: collect, exit and
    ///         eject must all revert NotPositionOwner.
    function valariRouterV3_probe_ownerOnPosition(uint256 idSeed) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        address owner = router.owner();
        if (depositorOf[tokenId] == owner) return;
        Pre memory pre = _prePosition(tokenId, owner);
        bool ok;
        bytes memory reason;
        vm.prank(owner);
        try router.collectFees(tokenId, block.timestamp) returns (ValariRouterV3.Payout memory) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        snapshotAfter();
        property_nonDepositorCannotAct(ok, reason, pre.known, owner, tokenId, "owner collectFees");

        ok = false;
        vm.prank(owner);
        try router.exitPosition(tokenId, 0, 0, block.timestamp) returns (ValariRouterV3.Payout memory) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        snapshotAfter();
        property_nonDepositorCannotAct(ok, reason, pre.known, owner, tokenId, "owner exitPosition");

        ok = false;
        vm.prank(owner);
        try router.ejectPosition(tokenId, owner) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        snapshotAfter();
        property_nonDepositorCannotAct(ok, reason, pre.known, owner, tokenId, "owner ejectPosition");
    }

    /// @notice The original depositor acts on one of its closed (exited or ejected) positions:
    ///         every position function must revert PositionClosed.
    function valariRouterV3_probe_closedPosition(uint256 idSeed) public {
        uint256 tokenId = _closedPositionId(idSeed);
        if (tokenId == 0) return;
        address depositor = depositorOf[tokenId];
        Pre memory pre = _prePosition(tokenId, depositor);
        bool ok;
        bytes memory reason;

        vm.prank(depositor);
        try router.collectFees(tokenId, block.timestamp) returns (ValariRouterV3.Payout memory) { ok = true; } catch (bytes memory r) { reason = r; }
        snapshotAfter();
        property_closedPositionsDead(ok, reason, pre.known, pre.wasClosed, depositor, tokenId, "collectFees");

        ok = false;
        vm.prank(depositor);
        try router.collectFeesTo(tokenId, depositor, block.timestamp) returns (ValariRouterV3.Payout memory) { ok = true; } catch (bytes memory r) { reason = r; }
        snapshotAfter();
        property_closedPositionsDead(ok, reason, pre.known, pre.wasClosed, depositor, tokenId, "collectFeesTo");

        ok = false;
        vm.prank(depositor);
        try router.exitPosition(tokenId, 0, 0, block.timestamp) returns (ValariRouterV3.Payout memory) { ok = true; } catch (bytes memory r) { reason = r; }
        snapshotAfter();
        property_closedPositionsDead(ok, reason, pre.known, pre.wasClosed, depositor, tokenId, "exitPosition");

        ok = false;
        vm.prank(depositor);
        try router.exitPositionTo(tokenId, depositor, 0, 0, block.timestamp) returns (ValariRouterV3.Payout memory) { ok = true; } catch (bytes memory r) { reason = r; }
        snapshotAfter();
        property_closedPositionsDead(ok, reason, pre.known, pre.wasClosed, depositor, tokenId, "exitPositionTo");

        ok = false;
        vm.prank(depositor);
        try router.ejectPosition(tokenId, depositor) { ok = true; } catch (bytes memory r) { reason = r; }
        snapshotAfter();
        property_closedPositionsDead(ok, reason, pre.known, pre.wasClosed, depositor, tokenId, "ejectPosition");
    }

    /// @notice An actor goes straight to the PositionManager with a custodied id: transferFrom and
    ///         a DECREASE_LIQUIDITY + TAKE_PAIR must both revert.
    function valariRouterV3_probe_directPositionManager(uint256 idSeed) public {
        uint256 tokenId = toOpenPositionId(idSeed);
        if (tokenId == 0) return;
        Pre memory pre = _prePosition(tokenId, actor);
        bool transferOk;
        bool modifyOk;
        vm.prank(actor);
        try IERC721(address(positionManager)).transferFrom(address(router), actor, tokenId) {
            transferOk = true;
        } catch {}
        PoolKey memory key = poolKeys[pre.pool];
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(pre.v.liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, actor);
        bytes memory data = abi.encode(
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params
        );
        vm.prank(actor);
        try positionManager.modifyLiquidities(data, block.timestamp) {
            modifyOk = true;
        } catch {}
        snapshotAfter();
        property_directPositionManagerProbe(transferOk, modifyOk, tokenId);
    }

    /// @notice Open then immediately exit (no pool activity): the rounding gap is the only loss.
    function valariRouterV3_openExitRoundTrip(uint256 poolSeed, uint128 amount0Max, uint128 amount1Max, uint8 rangeSeed)
        public
    {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = _clampBudget(pool, false, amount0Max);
        amount1Max = _clampBudget(pool, true, amount1Max);
        (bool quoted,, ValariRouterV3.DepositQuote memory quote) =
            _tryPreview(pool, amount0Max, amount1Max, lower, upper);
        if (!quoted) return;
        bool wasDisabled = router.depositsDisabled(poolIds[pool]);
        Outer memory before = _outer(pool, actor);

        (bool ok, bytes memory reason, OpenResult memory r) = valariRouterV3_openPosition(
            poolIds[pool], amount0Max, amount1Max, lower, upper, quote.liquidity, quote.sqrtPriceX96, quote.sqrtPriceX96, block.timestamp
        );
        property_depositLiveness(ok, reason, wasDisabled);
        if (!ok) return;
        property_openMatchesQuote(r, quote);
        property_boundaryPriceRounding(true, pool, lower, upper, r.amount0, r.amount1, quote.amount0, quote.amount1);

        // The unclamped exit asserts SP-13..SP-18, SP-21..SP-23 and SP-44 on its own snapshot pair.
        (bool ok2,, ValariRouterV3.Payout memory p) = valariRouterV3_exitPosition(r.tokenId, 0, 0, block.timestamp);
        if (!ok2) return; // SP-23 already failed inside
        Outer memory after_ = _outer(pool, actor);
        property_roundTripSingleCycle(r, p, before, after_);
        property_roundTripLiquidityNonExpanding(pool, p.amount0, p.amount1, lower, upper, r.liquidity);
        property_roundTripGapAtMostOne(r.amount0, p.amount0, r.amount1, p.amount1, "open -> exit");
        property_roundTripUserSideNonIncreasing(before, after_);
    }

    /// @notice n in [1, 5] consecutive open -> exit cycles, each funded only by the previous
    ///         payout (MANDATORY repeated-cycle dust extraction check).
    function valariRouterV3_openExitRoundTripN(
        uint256 poolSeed,
        uint128 amount0Max,
        uint128 amount1Max,
        uint8 rangeSeed,
        uint8 n
    ) public {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = _clampBudget(pool, false, amount0Max);
        amount1Max = _clampBudget(pool, true, amount1Max);
        uint256 cycles = clampBetween(uint256(n), 1, MAX_CYCLES);
        bool wasDisabled = router.depositsDisabled(poolIds[pool]);
        Outer memory before = _outer(pool, actor);

        for (uint256 i; i < cycles; ++i) {
            (bool quoted,, ValariRouterV3.DepositQuote memory quote) =
                _tryPreview(pool, amount0Max, amount1Max, lower, upper);
            if (!quoted) break; // proceeds too small to re-quote
            Cycle memory c;
            c.actorBal0Before = _token(pool, false).balanceOf(actor);
            c.actorBal1Before = _token(pool, true).balanceOf(actor);
            uint128 liq;
            vm.prank(actor);
            try router.openPosition(
                poolIds[pool], amount0Max, amount1Max, lower, upper, quote.liquidity, quote.sqrtPriceX96, quote.sqrtPriceX96, block.timestamp
            ) returns (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1) {
                c.tokenId = tokenId;
                liq = liquidity;
                c.spent0 = a0;
                c.spent1 = a1;
            } catch (bytes memory reason) {
                property_depositLiveness(false, reason, wasDisabled);
                return;
            }
            _recordPosition(c.tokenId, actor, pool, liq, c.spent0, c.spent1);
            vm.prank(actor);
            try router.exitPosition(c.tokenId, 0, 0, block.timestamp) returns (ValariRouterV3.Payout memory p) {
                c.p = p;
            } catch (bytes memory reason) {
                property_exitCollectLiveness(false, reason, "round-trip exitPosition");
                return;
            }
            _recordPayout(c.tokenId, c.p);
            _markExited(c.tokenId);
            ghosts.roundTripCycles += 1;
            property_roundTripNoProfitN_cycle(c, pool, actor);
            // Next cycle is funded only by what this one returned.
            amount0Max = c.p.amount0 > type(uint128).max ? type(uint128).max : uint128(c.p.amount0);
            amount1Max = c.p.amount1 > type(uint128).max ? type(uint128).max : uint128(c.p.amount1);
        }
        Outer memory after_ = _outer(pool, actor);
        property_roundTripNoProfitN(before, after_);
        property_roundTripUserSideNonIncreasing(before, after_);
    }

    /// @notice Open then immediately collect (no pool activity): a no-op payout.
    function valariRouterV3_openCollectRoundTrip(uint256 poolSeed, uint128 amount0Max, uint128 amount1Max, uint8 rangeSeed)
        public
    {
        uint256 pool = toPool(poolSeed);
        if (!listed[pool]) pool = 0;
        (int24 lower, int24 upper) = _range(pool, rangeSeed);
        amount0Max = _clampBudget(pool, false, amount0Max);
        amount1Max = _clampBudget(pool, true, amount1Max);
        (bool quoted,, ValariRouterV3.DepositQuote memory quote) =
            _tryPreview(pool, amount0Max, amount1Max, lower, upper);
        if (!quoted) return;
        bool wasDisabled = router.depositsDisabled(poolIds[pool]);
        Outer memory before = _outer(pool, actor);

        (bool ok, bytes memory reason, OpenResult memory r) = valariRouterV3_openPosition(
            poolIds[pool], amount0Max, amount1Max, lower, upper, quote.liquidity, quote.sqrtPriceX96, quote.sqrtPriceX96, block.timestamp
        );
        property_depositLiveness(ok, reason, wasDisabled);
        if (!ok) return;
        Outer memory mid = _outer(pool, actor);
        // The unclamped collect asserts SP-13..SP-17, SP-23 and SP-44 on its own snapshot pair.
        (bool ok2,, ValariRouterV3.Payout memory p) = valariRouterV3_collectFees(r.tokenId, block.timestamp);
        if (!ok2) return;
        Outer memory after_ = _outer(pool, actor);
        property_openCollectNoop(r, p, mid, after_);
        property_roundTripUserSideNonIncreasing(before, after_);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function valariRouterV3_collectFees(uint256 tokenId, uint256 deadline)
        public
        asActor
        returns (bool ok, bytes memory reason, ValariRouterV3.Payout memory p)
    {
        return _collect(tokenId, actor, deadline, false);
    }

    function valariRouterV3_collectFeesTo(uint256 tokenId, address to, uint256 deadline)
        public
        asActor
        returns (bool ok, bytes memory reason, ValariRouterV3.Payout memory p)
    {
        return _collect(tokenId, _payee(to), deadline, true);
    }

    function valariRouterV3_ejectPosition(uint256 tokenId, address to) public asActor returns (bool ok, bytes memory reason) {
        to = _payee(to);
        Pre memory pre = _prePosition(tokenId, to);
        bool wasEnabled = pre.known && router.ejectEnabled(pre.v.poolId);
        try router.ejectPosition(tokenId, to) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        snapshotAfter();
        property_closedPositionsDead(ok, reason, pre.known, pre.wasClosed, actor, tokenId, "ejectPosition");
        property_nonDepositorCannotAct(ok, reason, pre.known, actor, tokenId, "ejectPosition");
        if (_authorised(pre, tokenId, actor) && _validPayee(to)) {
            property_ejectGate(ok, reason, tokenId, wasEnabled);
        }
        if (ok) {
            _markEjected(tokenId, to);
            property_ejectPostconditions(tokenId, to, pre.v);
            property_poolStateUntouchedByRouterOps(pre.pool, 0);
        }
    }

    function valariRouterV3_exitPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, uint256 deadline)
        public
        asActor
        returns (bool ok, bytes memory reason, ValariRouterV3.Payout memory p)
    {
        return _exit(tokenId, actor, amount0Min, amount1Min, deadline, false);
    }

    function valariRouterV3_exitPositionTo(uint256 tokenId, address to, uint128 amount0Min, uint128 amount1Min, uint256 deadline)
        public
        asActor
        returns (bool ok, bytes memory reason, ValariRouterV3.Payout memory p)
    {
        return _exit(tokenId, _payee(to), amount0Min, amount1Min, deadline, true);
    }

    function valariRouterV3_openPosition(bytes32 poolId, uint128 amount0Max, uint128 amount1Max, int24 tickLower, int24 tickUpper, uint128 minLiquidity, uint160 sqrtPriceMinX96, uint160 sqrtPriceMaxX96, uint256 deadline)
        public
        asActor
        returns (bool ok, bytes memory reason, OpenResult memory r)
    {
        r.pool = _poolIndexOrDefault(poolId);
        r.depositor = actor;
        r.tickLower = tickLower;
        r.tickUpper = tickUpper;
        r.amount0Max = amount0Max;
        r.amount1Max = amount1Max;
        _setSnapshotTarget(r.pool, 0, actor);
        snapshotBefore();
        try router.openPosition(
            poolId, amount0Max, amount1Max, tickLower, tickUpper, minLiquidity, sqrtPriceMinX96, sqrtPriceMaxX96, deadline
        ) returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
            ok = true;
            r.tokenId = tokenId;
            r.liquidity = liquidity;
            r.amount0 = amount0;
            r.amount1 = amount1;
        } catch (bytes memory rs) {
            reason = rs;
        }
        snapshotAfter();
        if (!ok) return (ok, reason, r);

        r.wasRecorded = depositorOf[r.tokenId] != address(0);
        _recordPosition(r.tokenId, actor, r.pool, r.liquidity, r.amount0, r.amount1);
        property_openIdentityAndCounts(r);
        property_openTokenConservation(r);
        property_openNoCollateralChanges(r);
        property_noFreeLiquidity(r);
        (, int24 tick,,) = stateView.getSlot0(PoolId.wrap(poolId));
        bool inRange = tick >= tickLower && tick < tickUpper;
        property_poolStateUntouchedByRouterOps(r.pool, inRange ? int256(uint256(r.liquidity)) : int256(0));
        ValariRouterV3.PositionView memory v = router.getPosition(r.tokenId);
        property_roundTripGapAtMostOne(uint256(v.amount0Deposited), v.amount0, uint256(v.amount1Deposited), v.amount1, "deposit vs view after open");
    }

    function valariRouterV3_withdrawCommission(address token, address to, uint256 amount) public asActor returns (bool ok, bytes memory reason) {
        // Keep the holder set closed: a known token (0 kept for the router's own guard), an actor payee.
        if (token != address(0) && _tokenIndexOrNone(token) == NONE) {
            token = address(tokens[uint256(uint160(token)) % TOKENS]);
        }
        to = _payee(to);
        uint256 creditBefore = router.claimableCommission(actor, token);
        _setSnapshotTarget(0, 0, to == address(0) ? actor : to);
        snapshotBefore();
        try router.withdrawCommission(token, to, amount) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        snapshotAfter();
        property_overdrawReverts(ok, reason, actor, token, to, amount, creditBefore);
        if (ok) {
            _recordWithdraw(token, amount);
            property_withdrawPostconditions(actor, token, amount, creditBefore);
            property_poolStateUntouchedByRouterOps(0, 0);
        }
    }

    function _valariRouterV3_acceptOwnership() internal returns (AdminResult memory a) {
        address pending = router.pendingOwner();
        if (pending == address(0)) return a;
        a.prev = router.owner();
        a.pending = pending;
        vm.prank(pending);
        router.acceptOwnership();
        a.ok = true;
        // Keep the admin handlers alive after an ownership hand-over.
        admin = pending;
    }

    function _valariRouterV3_addPool(uint256 seed) internal asAdmin returns (AdminResult memory a) {
        a.pool = 1 + seed % (POOLS - 1);
        if (listed[a.pool]) return a;
        try router.addPool(poolKeys[a.pool]) returns (bytes32 id) {
            a.ok = true;
            a.id = id;
        } catch (bytes memory r) {
            a.reason = r;
            return a;
        }
        // An immediate second listing of the same key must be refused.
        try router.addPool(poolKeys[a.pool]) returns (bytes32) {
            a.dupOk = true;
        } catch (bytes memory r) {
            a.dupReason = r;
        }
    }

    function _valariRouterV3_setDepositsDisabled(bytes32 poolId, bool disabled) internal asAdmin returns (AdminResult memory a) {
        try router.setDepositsDisabled(poolId, disabled) {
            a.ok = true;
        } catch (bytes memory r) {
            a.reason = r;
        }
    }

    function _valariRouterV3_setEjectEnabled(bytes32 poolId, bool enabled) internal asAdmin returns (AdminResult memory a) {
        try router.setEjectEnabled(poolId, enabled) {
            a.ok = true;
        } catch (bytes memory r) {
            a.reason = r;
        }
    }

    function _valariRouterV3_setFeeRecipient(address newRecipient) internal asAdmin {
        router.setFeeRecipient(newRecipient);
        _noteRecipient(newRecipient);
    }

    function _valariRouterV3_transferOwnership(address newOwner) internal asAdmin {
        router.transferOwnership(newOwner);
    }

    // ――――――――――――――――――――――― Shared call paths ――――――――――――――――――――――

    /// @dev Raw collect / collectTo under the caller's prank, with the full specific-property set.
    function _collect(uint256 tokenId, address to, uint256 deadline, bool viaTo)
        internal
        returns (bool ok, bytes memory reason, ValariRouterV3.Payout memory p)
    {
        Pre memory pre = _prePosition(tokenId, to);
        if (viaTo) {
            try router.collectFeesTo(tokenId, to, deadline) returns (ValariRouterV3.Payout memory got) {
                ok = true;
                p = got;
            } catch (bytes memory r) {
                reason = r;
            }
        } else {
            try router.collectFees(tokenId, deadline) returns (ValariRouterV3.Payout memory got) {
                ok = true;
                p = got;
            } catch (bytes memory r) {
                reason = r;
            }
        }
        snapshotAfter();
        _afterPositionCall(pre, ok, reason, tokenId, to, false, p, 0, 0, deadline, viaTo ? "collectFeesTo" : "collectFees");
    }

    /// @dev Raw exit / exitTo under the caller's prank, with the full specific-property set.
    function _exit(uint256 tokenId, address to, uint128 min0, uint128 min1, uint256 deadline, bool viaTo)
        internal
        returns (bool ok, bytes memory reason, ValariRouterV3.Payout memory p)
    {
        Pre memory pre = _prePosition(tokenId, to);
        if (viaTo) {
            try router.exitPositionTo(tokenId, to, min0, min1, deadline) returns (ValariRouterV3.Payout memory got) {
                ok = true;
                p = got;
            } catch (bytes memory r) {
                reason = r;
            }
        } else {
            try router.exitPosition(tokenId, min0, min1, deadline) returns (ValariRouterV3.Payout memory got) {
                ok = true;
                p = got;
            } catch (bytes memory r) {
                reason = r;
            }
        }
        snapshotAfter();
        _afterPositionCall(pre, ok, reason, tokenId, to, true, p, min0, min1, deadline, viaTo ? "exitPositionTo" : "exitPosition");
    }

    /// @dev Revert expectations, liveness, ghosts and postconditions shared by collect and exit.
    ///      The caller is `actor` (the unclamped handlers run under `asActor`).
    function _afterPositionCall(
        Pre memory pre,
        bool ok,
        bytes memory reason,
        uint256 tokenId,
        address to,
        bool isExit,
        ValariRouterV3.Payout memory p,
        uint128 min0,
        uint128 min1,
        uint256 deadline,
        string memory what
    ) internal {
        property_closedPositionsDead(ok, reason, pre.known, pre.wasClosed, actor, tokenId, what);
        property_nonDepositorCannotAct(ok, reason, pre.known, actor, tokenId, what);
        if (
            _authorised(pre, tokenId, actor) && _validPayee(to) && deadline >= block.timestamp
                && min0 <= pre.v.amount0 && min1 <= pre.v.amount1
        ) {
            property_exitCollectLiveness(ok, reason, what);
        }
        if (!ok) return;

        _recordPayout(tokenId, p);
        if (isExit) _markExited(tokenId);

        PayoutCtx memory c = PayoutCtx(tokenId, pre.pool, actor, to, isExit, p, pre.v);
        property_payoutConservation(c);
        property_payoutCommissionCarry(c);
        property_exitPrincipalMatchesView(c);
        property_payoutFeesMatchView(c);
        if (isExit) {
            property_exitPostconditions(c);
            property_outOfRangePrincipalOneSided(c);
            property_boundaryPriceRounding(
                false, pre.pool, pre.v.tickLower, pre.v.tickUpper, p.principal0, p.principal1, pre.v.amount0, pre.v.amount1
            );
            property_poolStateUntouchedByRouterOps(
                pre.pool, pre.v.inRange ? -int256(uint256(pre.v.liquidity)) : int256(0)
            );
        } else {
            property_collectPostconditions(c);
            property_poolStateUntouchedByRouterOps(pre.pool, 0);
        }
    }

    /// @dev Pre-call facts about `tokenId`, then the before-snapshot targeted at it.
    function _prePosition(uint256 tokenId, address payee) internal returns (Pre memory pre) {
        try router.getPosition(tokenId) returns (ValariRouterV3.PositionView memory v) {
            pre.known = true;
            pre.wasClosed = v.closed;
            pre.v = v;
        } catch {}
        pre.custodied = _nftOwner(tokenId) == address(router);
        pre.pool = pre.known ? poolIndexOf[tokenId] : 0;
        _setSnapshotTarget(pre.pool, tokenId, payee == address(0) ? actor : payee);
        snapshotBefore();
    }

    /// @dev The caller is the recorded depositor of an open, custodied position.
    function _authorised(Pre memory pre, uint256 tokenId, address caller) internal view returns (bool) {
        return pre.known && !pre.wasClosed && pre.custodied && depositorOf[tokenId] == caller;
    }

    function _validPayee(address to) internal view returns (bool) {
        return to != address(0) && to != address(router);
    }

    /// @dev Payees stay inside the closed holder set; 0 and the router are kept so the router's
    ///      InvalidRecipient guard stays reachable (both revert, so nothing leaks).
    function _payee(address to) internal view returns (address) {
        if (to == address(0) || to == address(router)) return to;
        return toActor(to);
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// @dev Ranges aligned to the pool's tick spacing: symmetric narrow/wide around tick 0,
    ///      one-sided above / below it (single-token deposits), or with one boundary exactly at
    ///      tick 0 so the 1:1 seed price sits on a boundary sqrt price (SP-22).
    function _range(uint256 pool, uint8 seed) internal view returns (int24 lower, int24 upper) {
        int24 spacing = poolKeys[pool].tickSpacing;
        int24 narrow = spacing * 2;
        int24 wide = spacing * 20;
        uint8 kind = seed % 6;
        if (kind == 0) return (-narrow, narrow);
        if (kind == 1) return (-wide, wide);
        if (kind == 2) return (narrow, wide);
        if (kind == 3) return (-wide, -narrow);
        if (kind == 4) return (0, wide);
        return (-wide, 0);
    }

    function _clampBudget(uint256 pool, bool one, uint128 budget) internal returns (uint128) {
        uint256 balance = _token(pool, one).balanceOf(actor);
        if (balance == 0) return 0;
        uint256 cap = balance < MAX_BUDGET ? balance : MAX_BUDGET;
        return uint128(clampBetween(budget, 0, cap));
    }

    function _exitMinimums(uint256 tokenId, uint256 slippageBps) internal returns (uint128 min0, uint128 min1) {
        slippageBps = clampBetween(slippageBps, 0, 10_000);
        ValariRouterV3.PositionView memory p = router.getPosition(tokenId);
        min0 = uint128(p.amount0 * (10_000 - slippageBps) / 10_000);
        min1 = uint128(p.amount1 * (10_000 - slippageBps) / 10_000);
    }

    /// @dev Price bounds widened by `bps` on each side of `p`, clamped into (0, uint160.max].
    function _bounds(uint160 p, uint256 bps) internal pure returns (uint160 lo, uint160 hi) {
        uint256 l = uint256(p) * (10_000 - bps) / 10_000;
        uint256 h = uint256(p) * (10_000 + bps) / 10_000;
        lo = l == 0 ? 1 : uint160(l);
        hi = h > type(uint160).max ? type(uint160).max : uint160(h);
    }

    function _tryPreview(uint256 pool, uint128 amount0Max, uint128 amount1Max, int24 lower, int24 upper)
        internal
        view
        returns (bool ok, bytes memory reason, ValariRouterV3.DepositQuote memory q)
    {
        try router.previewDeposit(poolIds[pool], amount0Max, amount1Max, lower, upper)
            returns (ValariRouterV3.DepositQuote memory got)
        {
            ok = true;
            q = got;
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @dev Re-throws an assertion failure (Panic(0x01)) caught from an external self-call so a
    ///      property violation inside it is never swallowed; other reverts are dropped.
    function _rethrowAssert(bytes memory r) internal pure {
        if (r.length == 36 && _selector(r) == bytes4(0x4e487b71)) {
            uint256 code;
            assembly {
                code := mload(add(r, 36))
            }
            if (code == 1) {
                assembly {
                    revert(add(r, 32), mload(r))
                }
            }
        }
    }

    /// @dev Harness index of a pool id; 0 when it is not one of the harness pools (such an open
    ///      cannot succeed, the router reverts InvalidPool).
    function _poolIndexOrDefault(bytes32 poolId) internal view returns (uint256) {
        for (uint256 i; i < POOLS; ++i) {
            if (poolIds[i] == poolId) return i;
        }
        return 0;
    }

    /// @dev A position the harness opened that is still open in the router's records, scanning
    ///      forward from `seed`; 0 when every known position is closed.
    function toOpenPositionId(uint256 seed) internal view returns (uint256) {
        uint256 n = positionIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = positionIds[(seed + i) % n];
            if (!router.getPosition(id).closed) return id;
        }
        return 0;
    }

    /// @dev A harness position that is closed (exited or ejected), among the newest TAIL ids,
    ///      scanning from `seed`; 0 when none is closed.
    function _closedPositionId(uint256 seed) internal view returns (uint256) {
        uint256 n = positionIds.length;
        uint256 span = n < TAIL ? n : TAIL;
        if (span == 0) return 0;
        uint256 start = n - span;
        for (uint256 i; i < span; ++i) {
            uint256 id = positionIds[start + (seed + i) % span];
            if (ghosts.closedBy[id] != CLOSED_OPEN) return id;
        }
        return 0;
    }
}
