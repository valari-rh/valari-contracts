// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ValariRouterV3} from "../../../../src/ValariRouterV3.sol";

/// @dev Only ERC20s and transaction actors are simplified. Router, v4 managers,
/// StateView, and canonical Permit2 runtime are the repository's actual code.
contract AuditToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AuditActor {
    function invoke(address target, bytes memory data) external returns (bool, bytes memory) {
        return target.call(data);
    }
}

/// @notice Stateful properties for ValariRouterV3 over three pools: two fee tiers of one
/// stock (0.30% listed at deployment, 0.05% appended by the owner during the campaign) and a
/// second stock (1.00%, also appended). All three share the USDG token.
contract RouterEchidnaV3 is DeployPermit2, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant POOLS = 3;
    uint256 internal constant TOKENS = 3;

    PoolManager internal manager;
    PositionManager internal positions;
    StateView internal state;
    IAllowanceTransfer internal permit;
    ValariRouterV3 internal router;
    AuditToken[TOKENS] internal tokens; // 0 = USDG, 1 = stock A, 2 = stock B
    AuditActor[2] internal users;
    AuditActor[2] internal treasuries;
    PoolKey[POOLS] internal keys;
    bytes32[POOLS] internal poolIds;
    bool[POOLS] internal listed;
    bytes32[] internal listedOrder;
    uint256[] internal ids;
    mapping(uint256 => uint256) internal actorOf;
    mapping(uint256 => uint256) internal poolOf;
    uint256[TOKENS] internal dust;
    bool internal payoutsCorrect = true;
    bool internal accessCorrect = true;
    bool internal opensCorrect = true;
    bool internal catalogCorrect = true;
    bool internal boundsCorrect = true;
    bool internal switchesCorrect = true;
    bool[POOLS] internal depositsOff;
    bool[POOLS] internal ejectOn;
    mapping(uint256 => address) internal ejectedTo;
    // Reach counters, read only by RouterEchidnaV3Reach to prove the campaign gets there.
    uint256 internal added;
    uint256[POOLS] internal opened;
    uint256[POOLS] internal exited;
    uint256 internal commissionsCharged;
    uint256 internal withdrawals;
    uint256 internal movedPriceRejected;
    uint256 internal movedPriceAccepted;
    uint256 internal refusedDeposits;
    uint256 internal ejections;
    uint256 internal paidElsewhere;

    constructor() {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        permit = IAllowanceTransfer(deployPermit2());
        positions = new PositionManager(
            manager, permit, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        state = new StateView(manager);
        for (uint256 t; t < TOKENS; ++t) {
            tokens[t] = new AuditToken();
        }
        _makePool(0, 1, 3000, 60);
        _makePool(1, 1, 500, 10);
        _makePool(2, 2, 10_000, 200);

        PoolKey[] memory initial = new PoolKey[](1);
        initial[0] = keys[0];
        router = new ValariRouterV3(positions, state, address(tokens[0]), initial);
        listed[0] = true;
        listedOrder.push(poolIds[0]);

        dust[0] = 137;
        dust[1] = 251;
        dust[2] = 59;
        for (uint256 t; t < TOKENS; ++t) {
            for (uint256 i; i < 2; ++i) {
                if (t == 0) {
                    users[i] = new AuditActor();
                    treasuries[i] = new AuditActor();
                }
                tokens[t].mint(address(users[i]), 1_000_000 ether);
                users[i].invoke(
                    address(tokens[t]),
                    abi.encodeCall(AuditToken.approve, (address(router), type(uint256).max))
                );
            }
            tokens[t].mint(address(this), 1_000_000 ether);
            tokens[t].mint(address(router), dust[t]);
        }
        router.setFeeRecipient(address(treasuries[0]));
        _open(0, 0, 100 ether, 100 ether, -120, 120);
        _open(1, 0, 400 ether, 400 ether, -1200, 1200);
        require(ids.length == 2, "Initial positions must open");
    }

    function _makePool(uint256 pool, uint256 stock, uint24 fee, int24 spacing) internal {
        (address low, address high) = address(tokens[0]) < address(tokens[stock])
            ? (address(tokens[0]), address(tokens[stock]))
            : (address(tokens[stock]), address(tokens[0]));
        keys[pool] =
            PoolKey(Currency.wrap(low), Currency.wrap(high), fee, spacing, IHooks(address(0)));
        manager.initialize(keys[pool], uint160(1 << 96));
        poolIds[pool] = keccak256(abi.encode(keys[pool]));
    }

    function _token(uint256 pool, bool one) internal view returns (AuditToken) {
        return AuditToken(Currency.unwrap(one ? keys[pool].currency1 : keys[pool].currency0));
    }

    function _price(uint256 pool) internal view returns (uint160 price) {
        (price,,,) = state.getSlot0(PoolId.wrap(poolIds[pool]));
    }

    function _range(uint256 pool, uint8 range) internal view returns (int24 lower, int24 upper) {
        int24 narrow = keys[pool].tickSpacing == 200 ? int24(200) : int24(120);
        lower = range % 3 == 0 ? -narrow : int24(-1200);
        upper = range % 3 == 2 ? narrow : -lower;
    }

    // ---------------------------------------------------------------- catalog

    function actionAddPool(uint8 which) external {
        uint256 pool = 1 + which % 2;
        if (listed[pool]) return;
        uint256 countBefore = router.poolCount();
        bytes32 id = router.addPool(keys[pool]);
        listed[pool] = true;
        listedOrder.push(id);
        ++added;
        catalogCorrect =
            catalogCorrect && id == poolIds[pool] && router.poolCount() == countBefore + 1;
    }

    function actionCatalogAbuse(uint8 which, uint8 actor) external {
        uint256 pool = which % POOLS;
        AuditActor outsider = users[actor % 2];
        // Nobody but the owner lists a pool, listed or not.
        (bool outsiderAdd,) =
            outsider.invoke(address(router), abi.encodeCall(router.addPool, (keys[pool])));
        (bool treasuryAdd,) = treasuries[actor
                % 2].invoke(address(router), abi.encodeCall(router.addPool, (keys[pool])));
        catalogCorrect = catalogCorrect && !outsiderAdd && !treasuryAdd;
        if (listed[pool]) {
            // A listed pool cannot be listed again, even by the owner.
            (bool again,) = address(router).call(abi.encodeCall(router.addPool, (keys[pool])));
            catalogCorrect = catalogCorrect && !again;
        } else {
            // An unlisted pool accepts no deposit, although it is initialized on v4.
            uint256 before0 = _token(pool, false).balanceOf(address(outsider));
            (bool deposited,) = outsider.invoke(
                address(router),
                abi.encodeCall(
                    router.openPosition,
                    (
                        poolIds[pool],
                        1 ether,
                        1 ether,
                        int24(-1200),
                        int24(1200),
                        uint128(1),
                        TickMath.MIN_SQRT_PRICE,
                        TickMath.MAX_SQRT_PRICE,
                        block.timestamp
                    )
                )
            );
            catalogCorrect = catalogCorrect && !deposited
                && _token(pool, false).balanceOf(address(outsider)) == before0;
        }
    }

    // ---------------------------------------------------------------- deposits

    function actionOpen(uint8 actor, uint8 which, uint128 budget0, uint128 budget1, uint8 range)
        external
    {
        uint256 pool = which % POOLS;
        if (ids.length >= 12 || !listed[pool]) return;
        if (depositsOff[pool]) return _refused(actor % 2, pool);
        (int24 lower, int24 upper) = _range(pool, range);
        _open(
            actor % 2,
            pool,
            1_000_000 + budget0 % (100 ether),
            1_000_000 + budget1 % (100 ether),
            lower,
            upper
        );
    }

    function _open(uint256 actor, uint256 pool, uint128 b0, uint128 b1, int24 lower, int24 upper)
        internal
    {
        uint256 before0 = _token(pool, false).balanceOf(address(users[actor]));
        uint256 before1 = _token(pool, true).balanceOf(address(users[actor]));
        ValariRouterV3.DepositQuote memory q =
            router.previewDeposit(poolIds[pool], b0, b1, lower, upper);
        (bool ok, bytes memory result) = users[actor].invoke(
            address(router),
            abi.encodeCall(
                router.openPosition,
                (
                    poolIds[pool],
                    b0,
                    b1,
                    lower,
                    upper,
                    q.liquidity,
                    q.sqrtPriceX96,
                    q.sqrtPriceX96,
                    block.timestamp
                )
            )
        );
        if (!ok) {
            opensCorrect = false;
            return;
        }
        (uint256 id, uint128 liquidity, uint256 a0, uint256 a1) =
            abi.decode(result, (uint256, uint128, uint256, uint256));
        ids.push(id);
        actorOf[id] = actor;
        poolOf[id] = pool;
        ++opened[pool];
        opensCorrect = opensCorrect && liquidity == q.liquidity && a0 <= b0 && a1 <= b1
            && before0 - _token(pool, false).balanceOf(address(users[actor])) == a0
            && before1 - _token(pool, true).balanceOf(address(users[actor])) == a1;
    }

    /// @dev A switched-off pool takes no deposit and moves no funds, whatever the arguments.
    function _refused(uint256 actor, uint256 pool) internal {
        AuditActor user = users[actor];
        uint256 before0 = _token(pool, false).balanceOf(address(user));
        uint256 before1 = _token(pool, true).balanceOf(address(user));
        ValariRouterV3.DepositQuote memory q =
            router.previewDeposit(poolIds[pool], 1 ether, 1 ether, -1200, 1200);
        (bool ok,) = user.invoke(
            address(router),
            abi.encodeCall(
                router.openPosition,
                (
                    poolIds[pool],
                    1 ether,
                    1 ether,
                    int24(-1200),
                    int24(1200),
                    q.liquidity,
                    q.sqrtPriceX96,
                    q.sqrtPriceX96,
                    block.timestamp
                )
            )
        );
        ++refusedDeposits;
        switchesCorrect = switchesCorrect && !ok
            && _token(pool, false).balanceOf(address(user)) == before0
            && _token(pool, true).balanceOf(address(user)) == before1;
    }

    function actionSetDeposits(uint8 which, bool disabled) external {
        uint256 pool = which % POOLS;
        if (!listed[pool]) return;
        router.setDepositsDisabled(poolIds[pool], disabled);
        depositsOff[pool] = disabled;
        switchesCorrect = switchesCorrect && router.depositsDisabled(poolIds[pool]) == disabled;
    }

    function actionSetEject(uint8 which, bool enabled) external {
        uint256 pool = which % POOLS;
        if (!listed[pool]) return;
        router.setEjectEnabled(poolIds[pool], enabled);
        ejectOn[pool] = enabled;
        switchesCorrect = switchesCorrect && router.ejectEnabled(poolIds[pool]) == enabled;
    }

    /// @dev The depositor can take the NFT exactly when the owner enabled it for the pool.
    function actionEject(uint8 index, bool toOther) external {
        uint256 id = ids[index % ids.length];
        if (router.getPosition(id).closed) return;
        AuditActor actor = users[actorOf[id]];
        address to = toOther ? address(users[1 - actorOf[id]]) : address(actor);
        uint128 liquidity = positions.getPositionLiquidity(id);
        (bool ok,) = actor.invoke(address(router), abi.encodeCall(router.ejectPosition, (id, to)));
        if (!ejectOn[poolOf[id]]) {
            switchesCorrect = switchesCorrect && !ok && positions.ownerOf(id) == address(router);
            return;
        }
        ejectedTo[id] = to;
        ++ejections;
        switchesCorrect = switchesCorrect && ok && positions.ownerOf(id) == to
            && positions.getPositionLiquidity(id) == liquidity && router.getPosition(id).closed;
    }

    /// @dev Bounds that exclude the live price by one unit always stop the deposit.
    function actionOpenOutsideBounds(uint8 actor, uint8 which, bool above) external {
        uint256 pool = which % POOLS;
        if (!listed[pool]) return;
        AuditActor user = users[actor % 2];
        uint256 before0 = _token(pool, false).balanceOf(address(user));
        uint256 before1 = _token(pool, true).balanceOf(address(user));
        uint160 price = _price(pool);
        (uint160 low, uint160 high) =
            above ? (price + 1, TickMath.MAX_SQRT_PRICE) : (TickMath.MIN_SQRT_PRICE, price - 1);
        (bool ok,) = user.invoke(
            address(router),
            abi.encodeCall(
                router.openPosition,
                (
                    poolIds[pool],
                    10 ether,
                    10 ether,
                    int24(-1200),
                    int24(1200),
                    uint128(1),
                    low,
                    high,
                    block.timestamp
                )
            )
        );
        boundsCorrect = boundsCorrect && !ok
            && _token(pool, false).balanceOf(address(user)) == before0
            && _token(pool, true).balanceOf(address(user)) == before1;
    }

    /// @dev A deposit quoted before a swap and executed after it, with 0.1% sqrt-price bounds
    /// and a loose minimum liquidity: it either lands inside the bounds or moves nothing.
    function actionOpenAfterPriceMove(
        uint8 actor,
        uint8 which,
        bool zeroForOne,
        uint128 swapAmount,
        uint128 budget0,
        uint128 budget1,
        uint8 range
    ) external {
        uint256 pool = which % POOLS;
        if (ids.length >= 12 || !listed[pool] || depositsOff[pool]) return;
        AuditActor user = users[actor % 2];
        (int24 lower, int24 upper) = _range(pool, range);
        uint128 b0 = 1_000_000 + budget0 % (100 ether);
        uint128 b1 = 1_000_000 + budget1 % (100 ether);
        ValariRouterV3.DepositQuote memory q =
            router.previewDeposit(poolIds[pool], b0, b1, lower, upper);
        uint160 low = uint160(uint256(q.sqrtPriceX96) * 999 / 1000);
        uint160 high = uint160(uint256(q.sqrtPriceX96) * 1001 / 1000);

        try manager.unlock(
            abi.encode(pool, false, zeroForOne, 1 + uint256(swapAmount) % (80 ether), uint256(0))
        ) {}
            catch {}

        uint256 before0 = _token(pool, false).balanceOf(address(user));
        uint256 before1 = _token(pool, true).balanceOf(address(user));
        uint160 executed = _price(pool);
        (bool ok, bytes memory result) = user.invoke(
            address(router),
            abi.encodeCall(
                router.openPosition,
                (poolIds[pool], b0, b1, lower, upper, uint128(1), low, high, block.timestamp)
            )
        );
        if (!ok) {
            if (executed < low || executed > high) ++movedPriceRejected;
            boundsCorrect = boundsCorrect && _token(pool, false).balanceOf(address(user)) == before0
                && _token(pool, true).balanceOf(address(user)) == before1;
            return;
        }
        ++movedPriceAccepted;
        ++opened[pool];
        (uint256 id,,,) = abi.decode(result, (uint256, uint128, uint256, uint256));
        ids.push(id);
        actorOf[id] = actor % 2;
        poolOf[id] = pool;
        boundsCorrect = boundsCorrect && executed >= low && executed <= high;
    }

    // ---------------------------------------------------------------- market

    function actionSwap(uint8 which, bool zeroForOne, uint128 amount) external {
        // Failed swaps when no liquidity is active are valid v4 outcomes.
        try manager.unlock(
            abi.encode(
                which % POOLS, false, zeroForOne, 1 + uint256(amount) % (80 ether), uint256(0)
            )
        ) {}
            catch {}
    }

    function actionDonate(uint8 which, uint128 amount0, uint128 amount1) external {
        try manager.unlock(
            abi.encode(
                which % POOLS,
                true,
                false,
                uint256(amount0) % (1 ether),
                uint256(amount1) % (1 ether)
            )
        ) {}
            catch {}
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint256 pool, bool donate, bool zeroForOne, uint256 amount0, uint256 amount1) =
            abi.decode(data, (uint256, bool, bool, uint256, uint256));
        PoolKey memory key = keys[pool];
        BalanceDelta delta = donate
            ? manager.donate(key, amount0, amount1, "")
            : manager.swap(
                key,
                SwapParams(
                    zeroForOne,
                    -int256(amount0),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            manager.sync(currency);
            AuditToken(Currency.unwrap(currency))
                .transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }

    // ---------------------------------------------------------------- payouts

    function actionCollect(uint8 index, bool toOther) external {
        _payout(ids[index % ids.length], false, toOther);
    }

    function actionExit(uint8 index, bool toOther) external {
        _payout(ids[index % ids.length], true, toOther);
    }

    function _payoutCall(uint256 id, bool exit, address to, uint128 min0, uint128 min1)
        internal
        view
        returns (bytes memory)
    {
        if (to == address(0)) {
            return exit
                ? abi.encodeCall(router.exitPosition, (id, min0, min1, block.timestamp))
                : abi.encodeCall(router.collectFees, (id, block.timestamp));
        }
        return exit
            ? abi.encodeCall(router.exitPositionTo, (id, to, min0, min1, block.timestamp))
            : abi.encodeCall(router.collectFeesTo, (id, to, block.timestamp));
    }

    /// @dev Paid to the depositor through the plain entry points, or to the other user through
    /// the To variants; either way the destination receives exactly the reported payout.
    function _payout(uint256 id, bool exit, bool toOther) internal {
        ValariRouterV3.PositionView memory beforePosition = router.getPosition(id);
        if (beforePosition.closed) return;
        AuditActor actor = users[actorOf[id]];
        address payee = toOther ? address(users[1 - actorOf[id]]) : address(actor);
        AuditToken token0 = _token(poolOf[id], false);
        AuditToken token1 = _token(poolOf[id], true);
        uint256 before0 = token0.balanceOf(payee);
        uint256 before1 = token1.balanceOf(payee);
        uint256 depositor0 = token0.balanceOf(address(actor));
        uint256 credit0 = router.claimableCommission(router.feeRecipient(), address(token0));
        uint256 credit1 = router.claimableCommission(router.feeRecipient(), address(token1));
        bytes memory callData = _payoutCall(
            id,
            exit,
            toOther ? payee : address(0),
            uint128(beforePosition.amount0),
            uint128(beforePosition.amount1)
        );
        (bool ok, bytes memory result) = actor.invoke(address(router), callData);
        if (!ok) {
            payoutsCorrect = false;
            return;
        }
        ValariRouterV3.Payout memory p = abi.decode(result, (ValariRouterV3.Payout));
        if (exit) ++exited[poolOf[id]];
        if (toOther) {
            ++paidElsewhere;
            payoutsCorrect = payoutsCorrect && token0.balanceOf(address(actor)) == depositor0;
        }
        if (p.commission0 + p.commission1 != 0) ++commissionsCharged;
        payoutsCorrect = payoutsCorrect && p.principal0 == (exit ? beforePosition.amount0 : 0)
            && p.principal1 == (exit ? beforePosition.amount1 : 0)
            && p.fees0 == beforePosition.fees0 && p.fees1 == beforePosition.fees1
            && p.commission0 == beforePosition.commission0
            && p.commission1 == beforePosition.commission1
            && token0.balanceOf(payee) - before0 == p.amount0
            && token1.balanceOf(payee) - before1 == p.amount1
            && p.amount0 + p.commission0 == p.principal0 + p.fees0
            && p.amount1 + p.commission1 == p.principal1 + p.fees1
            && router.claimableCommission(router.feeRecipient(), address(token0))
                == credit0 + p.commission0
            && router.claimableCommission(router.feeRecipient(), address(token1))
                == credit1 + p.commission1;
    }

    function actionRotateRecipient(uint8 choice) external {
        router.setFeeRecipient(address(treasuries[choice % 2]));
    }

    function actionWithdraw(uint8 recipient, uint8 whichToken, uint256 amount) external {
        AuditActor actor = treasuries[recipient % 2];
        AuditToken token = tokens[whichToken % TOKENS];
        uint256 credit = router.claimableCommission(address(actor), address(token));
        if (credit == 0) return;
        amount = 1 + amount % credit;
        uint256 beforeBalance = token.balanceOf(address(actor));
        (bool ok,) = actor.invoke(
            address(router),
            abi.encodeCall(router.withdrawCommission, (address(token), address(actor), amount))
        );
        if (ok) ++withdrawals;
        payoutsCorrect = payoutsCorrect && ok
            && token.balanceOf(address(actor)) == beforeBalance + amount
            && router.claimableCommission(address(actor), address(token)) == credit - amount;
    }

    function actionUnauthorized(uint8 index, bool exit) external {
        uint256 id = ids[index % ids.length];
        AuditActor wrongActor = users[1 - actorOf[id]];
        bytes memory callData = exit
            ? abi.encodeCall(router.exitPosition, (id, uint128(0), uint128(0), block.timestamp))
            : abi.encodeCall(router.collectFees, (id, block.timestamp));
        (bool wrongUser,) = wrongActor.invoke(address(router), callData);
        (bool privilegedOwner,) = address(router).call(callData);
        (bool stealCredit,) = wrongActor.invoke(
            address(router),
            abi.encodeCall(router.withdrawCommission, (address(tokens[0]), address(wrongActor), 1))
        );
        (bool rotate,) = wrongActor.invoke(
            address(router), abi.encodeCall(router.setFeeRecipient, (address(wrongActor)))
        );
        accessCorrect = accessCorrect && !wrongUser && !privilegedOwner && !stealCredit && !rotate;
        _unauthorizedV3(id, wrongActor, exit);
    }

    /// @dev Neither another user nor the owner can redirect, eject or switch anything.
    function _unauthorizedV3(uint256 id, AuditActor wrongActor, bool exit) internal {
        bytes memory redirect = _payoutCall(id, exit, address(wrongActor), 0, 0);
        (bool wrongRedirect,) = wrongActor.invoke(address(router), redirect);
        (bool ownerRedirect,) = address(router).call(redirect);
        bytes memory eject = abi.encodeCall(router.ejectPosition, (id, address(wrongActor)));
        (bool wrongEject,) = wrongActor.invoke(address(router), eject);
        (bool ownerEject,) = address(router).call(eject);
        (bool wrongStop,) = wrongActor.invoke(
            address(router), abi.encodeCall(router.setDepositsDisabled, (poolIds[0], true))
        );
        (bool wrongEnable,) = wrongActor.invoke(
            address(router), abi.encodeCall(router.setEjectEnabled, (poolIds[0], true))
        );
        (bool wrongSelfCollect,) = wrongActor.invoke(
            address(router), abi.encodeCall(router.collectForEject, (id, address(wrongActor)))
        );
        (bool ownerSelfCollect,) =
            address(router).call(abi.encodeCall(router.collectForEject, (id, address(this))));
        (bool renounced,) = address(router).call(abi.encodeCall(router.renounceOwnership, ()));
        accessCorrect = accessCorrect && !wrongRedirect && !ownerRedirect && !wrongEject
            && !ownerEject && !wrongStop && !wrongEnable && !wrongSelfCollect && !ownerSelfCollect
            && !renounced && router.owner() == address(this);
    }

    function actionDust(uint8 whichToken, uint64 amount) external {
        uint256 t = whichToken % TOKENS;
        uint256 a = uint256(amount) % 1000;
        tokens[t].transfer(address(router), a);
        dust[t] += a;
    }

    // ---------------------------------------------------------------- properties

    function echidna_commission_is_backed_and_dust_preserved() external view returns (bool) {
        for (uint256 t; t < TOKENS; ++t) {
            address token = address(tokens[t]);
            uint256 total = router.totalClaimableCommission(token);
            if (tokens[t].balanceOf(address(router)) != dust[t] + total) return false;
            if (
                total
                    != router.claimableCommission(address(treasuries[0]), token)
                        + router.claimableCommission(address(treasuries[1]), token)
            ) return false;
        }
        return true;
    }

    function echidna_custody_and_cumulative_commission() external view returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            ValariRouterV3.PositionView memory p = router.getPosition(ids[i]);
            if (
                p.depositor != address(users[actorOf[ids[i]]])
                    || p.poolId != poolIds[poolOf[ids[i]]]
                    || p.poolKey.fee != keys[poolOf[ids[i]]].fee
                    || p.commissionAccrued0 != p.feesCollected0 / 10
                    || p.commissionAccrued1 != p.feesCollected1 / 10
            ) return false;
            address holder = ejectedTo[ids[i]];
            if (holder != address(0)) {
                if (!p.closed || p.nftOwner != holder || positions.ownerOf(ids[i]) != holder) {
                    return false;
                }
            } else if (p.closed
                    ? p.exists || p.nftOwner != address(0)
                    : !p.exists || p.nftOwner != address(router)
                        || positions.getPositionLiquidity(ids[i]) != p.initialLiquidity) {
                return false;
            }
        }
        return true;
    }

    function echidna_allowances_are_cleared() external view returns (bool) {
        for (uint256 t; t < TOKENS; ++t) {
            (uint160 permitted,,) =
                permit.allowance(address(router), address(tokens[t]), address(positions));
            if (permitted != 0 || tokens[t].allowance(address(router), address(permit)) != 0) {
                return false;
            }
        }
        return true;
    }

    function echidna_token_supply_is_conserved() external view returns (bool) {
        for (uint256 t; t < TOKENS; ++t) {
            AuditToken token = tokens[t];
            uint256 total = token.balanceOf(address(this)) + token.balanceOf(address(manager))
                + token.balanceOf(address(positions)) + token.balanceOf(address(router))
                + token.balanceOf(address(permit));
            for (uint256 i; i < 2; ++i) {
                total += token.balanceOf(address(users[i]))
                + token.balanceOf(address(treasuries[i]));
            }
            if (total != token.totalSupply()) return false;
        }
        return true;
    }

    /// @dev The catalog only grows, keeps its order, and agrees with the per-stock lists.
    function echidna_catalog_is_append_only_and_consistent() external view returns (bool) {
        if (!catalogCorrect || router.poolCount() != listedOrder.length) return false;
        for (uint256 i; i < listedOrder.length; ++i) {
            if (router.getPoolIds(i, 1)[0] != listedOrder[i]) return false;
        }
        uint256 perStock;
        for (uint256 pool; pool < POOLS; ++pool) {
            if (!listed[pool]) continue;
            PoolKey memory stored = router.getPoolKey(poolIds[pool]);
            if (
                stored.fee != keys[pool].fee || stored.tickSpacing != keys[pool].tickSpacing
                    || Currency.unwrap(stored.currency0) != Currency.unwrap(keys[pool].currency0)
                    || Currency.unwrap(stored.currency1) != Currency.unwrap(keys[pool].currency1)
            ) return false;
            ++perStock;
        }
        uint256 stockA = router.stockPoolCount(address(tokens[1]));
        uint256 stockB = router.stockPoolCount(address(tokens[2]));
        if (stockA != (listed[1] ? 2 : 1) || stockB != (listed[2] ? 1 : 0)) return false;
        if (router.stockPoolCount(address(tokens[0])) != 0) return false;
        if (router.getStockPoolIds(address(tokens[1]), 0, 1)[0] != poolIds[0]) return false;
        return stockA + stockB == perStock;
    }

    function echidna_payouts_match_actual_balance_changes() external view returns (bool) {
        return payoutsCorrect;
    }

    function echidna_owner_and_outsiders_cannot_take_positions() external view returns (bool) {
        return accessCorrect;
    }

    function echidna_deposit_budget_refund_and_quote() external view returns (bool) {
        return opensCorrect;
    }

    function echidna_price_bounds_hold() external view returns (bool) {
        return boundsCorrect;
    }

    /// @dev Deposits are refused exactly while a pool is switched off, and a position can be
    /// ejected exactly while the owner allows it for that pool; the stored flags agree.
    function echidna_pool_switches_hold() external view returns (bool) {
        if (!switchesCorrect) return false;
        for (uint256 pool; pool < POOLS; ++pool) {
            if (
                router.depositsDisabled(poolIds[pool]) != depositsOff[pool]
                    || router.ejectEnabled(poolIds[pool]) != ejectOn[pool]
            ) return false;
        }
        return true;
    }
}

/// @notice Reachability witnesses. Each property is written to FAIL once the campaign has
/// driven the router through the named behaviour, so a "failed" result here is the proof
/// that the passing properties above were exercised on those paths, not vacuously true.
contract RouterEchidnaV3Reach is RouterEchidnaV3 {
    function echidna_reach_appended_pools_opened_and_exited() external view returns (bool) {
        return !(added == 2 && opened[1] != 0 && opened[2] != 0 && exited[1] != 0 && exited[2] != 0
                && exited[0] != 0);
    }

    function echidna_reach_commission_charged_and_withdrawn() external view returns (bool) {
        return !(commissionsCharged >= 3 && withdrawals != 0);
    }

    function echidna_reach_moved_price_rejected_and_accepted() external view returns (bool) {
        return !(movedPriceRejected != 0 && movedPriceAccepted != 0);
    }

    function echidna_reach_refused_ejected_and_paid_elsewhere() external view returns (bool) {
        return !(refusedDeposits != 0 && ejections >= 2 && paidElsewhere >= 2);
    }
}
