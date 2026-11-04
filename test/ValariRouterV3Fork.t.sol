// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ValariRouterV3} from "../src/ValariRouterV3.sol";
import {DeployValariRouterV3} from "../script/DeployValariRouterV3.s.sol";
import {AddValariRouterV3Pools} from "../script/AddValariRouterV3Pools.s.sol";

/// @notice Opt-in tests against Robinhood's deployed v4 managers and actual stock tokens.
/// @dev RUN_ROBINHOOD_FORK=true forge test --match-contract ValariRouterV3ForkTest -vv
/// Optionally set ROBINHOOD_FORK_BLOCK if the RPC retains that block's storage; the public
/// endpoint may prune old state. All actions run on an isolated local fork using synthetic
/// balances, without private keys or broadcasts.
abstract contract ValariRouterV3ForkBase is Test, IUnlockCallback {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    bytes32 internal constant GOOGL_POOL =
        0xd4ecb79fdc521d7725d22b33ed43cb4e47aa96bfad76aa29577e3151f723ac5e;
    bytes32 internal constant NVDA_POOL =
        0x3bb34a44f1b2b5f32c034c38a53065a521a47b199700fa9bd19d60985ff24bf1;

    ValariRouterV3 internal router;
    IPositionManager internal positionManager;
    IStateView internal stateView;
    address internal user = makeAddr("Valari fork depositor");
    address internal outsider = makeAddr("Valari fork outsider");
    address internal treasury = makeAddr("Valari fork commission recipient");

    function setUp() public {
        if (!vm.envOr("RUN_ROBINHOOD_FORK", false)) return;
        uint256 forkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork("robinhood");
        else vm.createSelectFork("robinhood", forkBlock);
        assertEq(block.chainid, 4663, "Wrong fork chain");
        positionManager = IPositionManager(POSITION_MANAGER);
        stateView = IStateView(STATE_VIEW);
        string memory config = vm.readFile("config/robinhood.json");
        PoolKey[] memory pools = abi.decode(vm.parseJsonBytes(config, ".poolKeysAbi"), (PoolKey[]));
        assertEq(pools.length, 100);
        assertEq(vm.parseJsonUint(config, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(config, ".positionManager"), POSITION_MANAGER);
        assertEq(vm.parseJsonAddress(config, ".stateView"), STATE_VIEW);
        assertEq(vm.parseJsonAddress(config, ".usdg"), USDG);
        router = new ValariRouterV3(positionManager, stateView, USDG, pools);
        assertEq(router.poolCount(), 100);
        assertEq(router.stockPoolCount(GOOGL), 1);
        assertEq(router.getStockPoolIds(GOOGL, 0, 1)[0], GOOGL_POOL);
        assertEq(router.stockPoolCount(NVDA), 1);
        assertEq(router.getStockPoolIds(NVDA, 0, 1)[0], NVDA_POOL);
        assertEq(router.feeRecipient(), address(this));
        router.setFeeRecipient(treasury);
    }

    modifier onlyFork() {
        vm.skip(!vm.envOr("RUN_ROBINHOOD_FORK", false));
        _;
    }

    function _centerTick(bytes32 poolId, int24 spacing) internal view returns (int24 center) {
        (, int24 tick,,) = stateView.getSlot0(PoolId.wrap(poolId));
        center = (tick / spacing) * spacing;
        if (tick < 0 && tick % spacing != 0) center -= spacing;
    }

    function _openFor(
        address beneficiary,
        bytes32 poolId,
        uint128 budget0,
        uint128 budget1,
        int24 lower,
        int24 upper
    ) internal returns (uint256 tokenId) {
        PoolKey memory key = router.getPoolKey(poolId);
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(poolId, budget0, budget1, lower, upper);
        deal(address(token0), beneficiary, budget0);
        deal(address(token1), beneficiary, budget1);
        vm.startPrank(beneficiary);
        token0.approve(address(router), budget0);
        token1.approve(address(router), budget1);
        (tokenId,,,) = router.openPosition(
            poolId,
            budget0,
            budget1,
            lower,
            upper,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp + 300
        );
        vm.stopPrank();
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), address(router));
    }

    function _swapToTick(bytes32 poolId, bool zeroForOne, int24 targetTick) internal {
        PoolKey memory key = router.getPoolKey(poolId);
        IERC20 input = IERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1));
        IERC20 output = IERC20(Currency.unwrap(zeroForOne ? key.currency1 : key.currency0));
        // Finite funding caps, in real token units. The price limit controls actual spending.
        uint256 cap = address(input) == USDG ? 1_000_000e6 : 2_000 ether;
        assertLe(cap, input.totalSupply(), "Synthetic trade cap must stay within actual supply");
        uint160 limit = TickMath.getSqrtPriceAtTick(targetTick);
        (uint160 beforePrice,,,) = stateView.getSlot0(PoolId.wrap(poolId));
        if (zeroForOne) assertLt(limit, beforePrice);
        else assertGt(limit, beforePrice);
        deal(address(input), address(this), cap);
        uint256 beforeOutput = output.balanceOf(address(this));
        router.poolManager().unlock(abi.encode(false, key, zeroForOne, cap, uint256(0), limit));
        (uint160 afterPrice, int24 afterTick,,) = stateView.getSlot0(PoolId.wrap(poolId));
        assertEq(afterPrice, limit, "Bounded swap must reach the requested price");
        assertLt(input.balanceOf(address(this)), cap, "Swap must consume input");
        assertGt(output.balanceOf(address(this)), beforeOutput, "Swap must produce output");
        emit log_named_address("Swap input currency", address(input));
        emit log_named_uint("Swap input spent", cap - input.balanceOf(address(this)));
        emit log_named_int("Swap reached tick", afterTick);
    }

    function _checkLifecycle(bytes32 poolId, uint128 budget0, uint128 budget1) internal {
        PoolKey memory key = router.getPoolKey(poolId);
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        (, int24 tick,,) = stateView.getSlot0(PoolId.wrap(poolId));
        int24 center = (tick / key.tickSpacing) * key.tickSpacing;
        int24 lower = center - 1200;
        int24 upper = center + 1200;
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(poolId, budget0, budget1, lower, upper);
        assertGt(quote.liquidity, 0);
        assertLe(quote.amount0, budget0);
        assertLe(quote.amount1, budget1);

        deal(address(token0), user, budget0);
        deal(address(token1), user, budget1);
        vm.startPrank(user);
        token0.approve(address(router), budget0);
        token1.approve(address(router), budget1);
        (uint256 tokenId, uint128 liquidity, uint256 paid0, uint256 paid1) = router.openPosition(
            poolId,
            budget0,
            budget1,
            lower,
            upper,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp + 300
        );
        vm.stopPrank();

        assertEq(liquidity, quote.liquidity);
        assertEq(paid0, quote.amount0);
        assertEq(paid1, quote.amount1);
        assertEq(token0.balanceOf(user), uint256(budget0) - paid0);
        assertEq(token1.balanceOf(user), uint256(budget1) - paid1);
        assertGt(token0.balanceOf(user) + token1.balanceOf(user), 0, "Unused budget was refunded");
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
        assertEq(token0.allowance(address(router), address(router.permit2())), 0);
        assertEq(token1.allowance(address(router), address(router.permit2())), 0);
        (uint160 permitted0,,) =
            router.permit2().allowance(address(router), address(token0), POSITION_MANAGER);
        (uint160 permitted1,,) =
            router.permit2().allowance(address(router), address(token1), POSITION_MANAGER);
        assertEq(permitted0, 0);
        assertEq(permitted1, 0);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), address(router));
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);

        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
        assertTrue(position.exists);
        assertTrue(position.inRange);
        assertEq(position.poolId, poolId);
        assertEq(position.owner, user);
        assertEq(position.nftOwner, address(router));
        assertEq(position.depositor, user);
        assertFalse(position.closed);
        assertEq(position.liquidity, liquidity);
        assertEq(position.tickLower, lower);
        assertEq(position.tickUpper, upper);
        assertEq(position.amount0Deposited, paid0);
        assertEq(position.amount1Deposited, paid1);
        assertApproxEqAbs(position.amount0, paid0, 1);
        assertApproxEqAbs(position.amount1, paid1, 1);
        assertEq(position.fees0, 0);
        assertEq(position.fees1, 0);
        (ValariRouterV3.PositionView[] memory positions, uint256 nextCursor) =
            router.getUserPositions(user, 0, 100);
        assertEq(positions.length, 1);
        assertEq(positions[0].tokenId, tokenId);
        assertEq(nextCursor, router.depositCount(user));

        _checkNoCustodyBypass(tokenId, liquidity, key);

        // Real donations update live pool fee growth without changing its price or principal.
        // Only the synthetic donor is funded; the live managers and tokens are unmodified.
        _donate(key, budget0, budget1);
        position = router.getPosition(tokenId);
        assertGt(position.fees0, 100);
        assertGt(position.fees1, 100);
        uint256[10] memory balances = _balances(token0, token1);
        vm.prank(user);
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp + 300);
        assertEq(collected.principal0, 0);
        assertEq(collected.principal1, 0);
        assertEq(collected.fees0, position.fees0);
        assertEq(collected.fees1, position.fees1);
        _assertPayout(token0, token1, collected, balances, position);
        position = router.getPosition(tokenId);
        assertEq(position.liquidity, liquidity);
        assertEq(position.fees0, 0);
        assertEq(position.fees1, 0);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), address(router));

        // Collecting twice cannot pay the same fees or commission again.
        balances = _balances(token0, token1);
        vm.prank(user);
        collected = router.collectFees(tokenId, block.timestamp + 300);
        assertEq(collected.fees0, 0);
        assertEq(collected.fees1, 0);
        _assertPayout(token0, token1, collected, balances, position);

        _donate(key, budget0, budget1);
        position = router.getPosition(tokenId);
        balances = _balances(token0, token1);
        vm.prank(user);
        ValariRouterV3.Payout memory exited = router.exitPosition(
            tokenId, uint128(position.amount0), uint128(position.amount1), block.timestamp + 300
        );
        assertEq(exited.principal0, position.amount0);
        assertEq(exited.principal1, position.amount1);
        assertEq(exited.fees0, position.fees0);
        assertEq(exited.fees1, position.fees1);
        _assertPayout(token0, token1, exited, balances, position);
        // Fees alone incur 10%; the full principal is included in the user's payout.
        assertEq(exited.amount0 - (exited.fees0 - exited.commission0), position.amount0);
        assertEq(exited.amount1 - (exited.fees1 - exited.commission1), position.amount1);

        position = router.getPosition(tokenId);
        assertTrue(position.closed);
        assertFalse(position.exists);
        assertEq(position.owner, user);
        assertEq(position.depositor, user);
        assertEq(position.nftOwner, address(0));
        assertEq(position.liquidity, 0);
        assertEq(position.amount0, 0);
        assertEq(position.amount1, 0);
        assertEq(position.fees0, 0);
        assertEq(position.fees1, 0);
        vm.expectRevert();
        IERC721(POSITION_MANAGER).ownerOf(tokenId);
        (positions,) = router.getUserPositions(user, 0, 100);
        assertEq(positions.length, 0);
        vm.prank(user);
        vm.expectRevert();
        router.exitPosition(tokenId, 0, 0, block.timestamp + 300);
        _withdrawTreasuryCommissions(token0, token1);
        emit log_named_uint("Robinhood fork block", block.number);
        emit log_named_uint("Minted token ID", tokenId);
        emit log_named_uint("Minted liquidity", liquidity);
        emit log_named_uint("Exit currency0 fees", exited.fees0);
        emit log_named_uint("Exit currency0 commission", exited.commission0);
        emit log_named_uint("Exit currency1 fees", exited.fees1);
        emit log_named_uint("Exit currency1 commission", exited.commission1);
    }

    function _checkNoCustodyBypass(uint256 tokenId, uint128 liquidity, PoolKey memory key)
        internal
    {
        vm.prank(user);
        vm.expectRevert();
        IERC721(POSITION_MANAGER).transferFrom(address(router), user, tokenId);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, user);
        vm.prank(user);
        vm.expectRevert();
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)),
                params
            ),
            block.timestamp + 300
        );
        vm.prank(outsider);
        vm.expectRevert();
        router.collectFees(tokenId, block.timestamp + 300);
        vm.prank(outsider);
        vm.expectRevert();
        router.exitPosition(tokenId, 0, 0, block.timestamp + 300);
        vm.prank(outsider);
        vm.expectRevert();
        router.setFeeRecipient(outsider);
        assertEq(router.feeRecipient(), treasury);
    }

    function _donate(PoolKey memory key, uint256 amount0, uint256 amount1) internal {
        deal(Currency.unwrap(key.currency0), address(this), amount0);
        deal(Currency.unwrap(key.currency1), address(this), amount1);
        router.poolManager().unlock(abi.encode(true, key, false, amount0, amount1, uint160(0)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager manager = router.poolManager();
        require(msg.sender == address(manager), "Unexpected unlock caller");
        (
            bool donation,
            PoolKey memory key,
            bool zeroForOne,
            uint256 amount0,
            uint256 amount1,
            uint160 limit
        ) = abi.decode(data, (bool, PoolKey, bool, uint256, uint256, uint160));
        BalanceDelta delta = donation
            ? manager.donate(key, amount0, amount1, "")
            : manager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amount0),
                    sqrtPriceLimitX96: limit
                }),
                ""
            );
        _settle(manager, key.currency0, delta.amount0());
        _settle(manager, key.currency1, delta.amount1());
        return "";
    }

    function _settle(IPoolManager manager, Currency currency, int128 delta) internal {
        if (delta < 0) {
            manager.sync(currency);
            require(
                IERC20(Currency.unwrap(currency))
                    .transfer(address(manager), uint256(-int256(delta))),
                "Settlement transfer failed"
            );
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }

    function _balances(IERC20 token0, IERC20 token1)
        internal
        view
        returns (uint256[10] memory balances)
    {
        balances[0] = token0.balanceOf(user);
        balances[1] = token1.balanceOf(user);
        balances[2] = token0.balanceOf(treasury);
        balances[3] = token1.balanceOf(treasury);
        balances[4] = token0.balanceOf(address(router));
        balances[5] = token1.balanceOf(address(router));
        balances[6] = router.claimableCommission(treasury, address(token0));
        balances[7] = router.claimableCommission(treasury, address(token1));
        balances[8] = router.totalClaimableCommission(address(token0));
        balances[9] = router.totalClaimableCommission(address(token1));
    }

    function _withdrawTreasuryCommissions(IERC20 token0, IERC20 token1) internal {
        uint256 user0 = token0.balanceOf(user);
        uint256 user1 = token1.balanceOf(user);
        _withdrawTreasuryCommission(token0);
        _withdrawTreasuryCommission(token1);
        assertEq(token0.balanceOf(user), user0, "Treasury withdrawal does not affect user funds");
        assertEq(token1.balanceOf(user), user1, "Treasury withdrawal does not affect user funds");
    }

    function _withdrawTreasuryCommission(IERC20 token) internal {
        uint256 accrued = router.claimableCommission(treasury, address(token));
        if (accrued == 0) return;
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 routerBefore = token.balanceOf(address(router));
        uint256 reservedBefore = router.totalClaimableCommission(address(token));
        vm.prank(treasury);
        router.withdrawCommission(address(token), treasury, accrued);
        assertEq(token.balanceOf(treasury), treasuryBefore + accrued);
        assertEq(token.balanceOf(address(router)), routerBefore - accrued);
        assertEq(router.claimableCommission(treasury, address(token)), 0);
        assertEq(router.totalClaimableCommission(address(token)), reservedBefore - accrued);
        // These scenarios accrue to one treasury and start without router dust.
        assertEq(token.balanceOf(address(router)), 0);
    }

    function _assertPayout(
        IERC20 token0,
        IERC20 token1,
        ValariRouterV3.Payout memory payout,
        uint256[10] memory beforeBalances,
        ValariRouterV3.PositionView memory beforePosition
    ) internal view {
        // Commission uses cumulative fee totals so splitting claims cannot evade rounding.
        assertEq(
            payout.commission0,
            (beforePosition.feesCollected0 + payout.fees0) / 10 - beforePosition.commissionAccrued0
        );
        assertEq(
            payout.commission1,
            (beforePosition.feesCollected1 + payout.fees1) / 10 - beforePosition.commissionAccrued1
        );
        assertEq(payout.commission0, beforePosition.commission0);
        assertEq(payout.commission1, beforePosition.commission1);
        assertEq(payout.amount0, payout.principal0 + payout.fees0 - payout.commission0);
        assertEq(payout.amount1, payout.principal1 + payout.fees1 - payout.commission1);
        assertEq(token0.balanceOf(user), beforeBalances[0] + payout.amount0);
        assertEq(token1.balanceOf(user), beforeBalances[1] + payout.amount1);
        assertEq(token0.balanceOf(treasury), beforeBalances[2]);
        assertEq(token1.balanceOf(treasury), beforeBalances[3]);
        assertEq(token0.balanceOf(address(router)), beforeBalances[4] + payout.commission0);
        assertEq(token1.balanceOf(address(router)), beforeBalances[5] + payout.commission1);
        assertEq(
            router.claimableCommission(treasury, address(token0)),
            beforeBalances[6] + payout.commission0
        );
        assertEq(
            router.claimableCommission(treasury, address(token1)),
            beforeBalances[7] + payout.commission1
        );
        assertEq(
            router.totalClaimableCommission(address(token0)), beforeBalances[8] + payout.commission0
        );
        assertEq(
            router.totalClaimableCommission(address(token1)), beforeBalances[9] + payout.commission1
        );
        ValariRouterV3.PositionView memory afterPosition =
            router.getPosition(beforePosition.tokenId);
        assertEq(afterPosition.feesCollected0, beforePosition.feesCollected0 + payout.fees0);
        assertEq(afterPosition.feesCollected1, beforePosition.feesCollected1 + payout.fees1);
        assertEq(afterPosition.commissionAccrued0, afterPosition.feesCollected0 / 10);
        assertEq(afterPosition.commissionAccrued1, afterPosition.feesCollected1 / 10);
    }
}

/// @notice Four lifecycle scenarios using live Robinhood tokens and v4 contracts.
contract ValariRouterV3ForkTest is ValariRouterV3ForkBase {
    function testForkOwnerAppendsRealPoolToPartialCatalog() public onlyFork {
        string memory config = vm.readFile("config/robinhood.json");
        PoolKey[] memory all = abi.decode(vm.parseJsonBytes(config, ".poolKeysAbi"), (PoolKey[]));
        bytes32[] memory ids = vm.parseJsonBytes32Array(config, ".poolIds");
        PoolKey[] memory initial = new PoolKey[](99);
        for (uint256 i; i < 99; ++i) {
            initial[i] = all[i];
        }
        ValariRouterV3 partialRouter = new ValariRouterV3(positionManager, stateView, USDG, initial);
        assertEq(partialRouter.poolCount(), 99);
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, ids[99]));
        partialRouter.getPoolKey(ids[99]);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        vm.prank(outsider);
        partialRouter.addPool(all[99]);

        assertEq(partialRouter.addPool(all[99]), ids[99]);
        assertEq(partialRouter.poolCount(), 100);
        assertEq(partialRouter.getPoolIds(99, 1)[0], ids[99]);
        for (uint256 i; i < 100; ++i) {
            assertEq(router.getPoolIds(i, 1)[0], ids[i], "full catalog keeps config order");
        }
    }

    function testForkDeployScriptListsTheCuratedPoolsInOrder() public onlyFork {
        ValariRouterV3 deployed = new DeployValariRouterV3().run();
        string memory curated = vm.readFile("config/robinhood-curated.json");
        bytes32[] memory ids = vm.parseJsonBytes32Array(curated, ".poolIds");
        bytes32[] memory full =
            vm.parseJsonBytes32Array(vm.readFile("config/robinhood.json"), ".poolIds");
        assertEq(deployed.poolCount(), ids.length);
        assertLt(ids.length, full.length, "curated is a strict subset of the full catalog");
        assertEq(deployed.owner(), deployed.feeRecipient());
        assertEq(address(deployed.positionManager()), POSITION_MANAGER);
        assertEq(address(deployed.stateView()), STATE_VIEW);
        assertEq(deployed.usdg(), USDG);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(deployed.getPoolIds(i, 1)[0], ids[i]);
            bool inFull;
            for (uint256 j; j < full.length && !inFull; ++j) {
                inFull = full[j] == ids[i];
            }
            assertTrue(inFull, "every curated pool is in the full catalog");
        }
        assertEq(deployed.stockPoolCount(GOOGL), 1);
        assertEq(deployed.getStockPoolIds(GOOGL, 0, 1)[0], GOOGL_POOL);
        assertEq(deployed.stockPoolCount(NVDA), 1);
        assertEq(deployed.getStockPoolIds(NVDA, 0, 1)[0], NVDA_POOL);
    }

    function testForkAddPoolsScriptCompletesPartialCatalogAndIsIdempotent() public onlyFork {
        string memory config = vm.readFile("config/robinhood.json");
        PoolKey[] memory all = abi.decode(vm.parseJsonBytes(config, ".poolKeysAbi"), (PoolKey[]));
        bytes32[] memory ids = vm.parseJsonBytes32Array(config, ".poolIds");
        PoolKey[] memory initial = new PoolKey[](97);
        for (uint256 i; i < 97; ++i) {
            initial[i] = all[i];
        }
        ValariRouterV3 partialRouter = new ValariRouterV3(positionManager, stateView, USDG, initial);
        // Scripts broadcast from the default sender; make it the owner, as a deployer would be.
        partialRouter.transferOwnership(DEFAULT_SENDER);
        vm.prank(DEFAULT_SENDER);
        partialRouter.acceptOwnership();
        vm.setEnv("VALARI_ROUTER_V3", vm.toString(address(partialRouter)));

        AddValariRouterV3Pools script = new AddValariRouterV3Pools();
        assertEq(script.run(), 3);
        assertEq(partialRouter.poolCount(), 100);
        for (uint256 i; i < 100; ++i) {
            assertEq(partialRouter.getPoolIds(i, 1)[0], ids[i]);
        }
        assertEq(script.run(), 0, "second run adds nothing");
        assertEq(partialRouter.poolCount(), 100);
    }

    function testForkSecondGoogleFeeTierIsListedAndRunsFullLifecycle() public onlyFork {
        // The deployed 0.05% GOOGL/USDG pool, next to the catalog's 0.30% one.
        PoolKey memory tier = router.getPoolKey(GOOGL_POOL);
        tier.fee = 500;
        tier.tickSpacing = 10;
        bytes32 tierId = 0xe79893434bd23d7c63d24424315008509c469696d1f460301122806dad531748;
        assertEq(keccak256(abi.encode(tier)), tierId);

        assertEq(router.addPool(tier), tierId);
        assertEq(router.poolCount(), 101);
        assertEq(router.stockPoolCount(GOOGL), 2);
        bytes32[] memory tiers = router.getStockPoolIds(GOOGL, 0, 100);
        assertEq(tiers[0], GOOGL_POOL);
        assertEq(tiers[1], tierId);
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.DuplicatePool.selector, tierId));
        router.addPool(tier);

        _checkLifecycle(tierId, 10 ether, 10_000e6);
        _checkLifecycle(GOOGL_POOL, 10 ether, 10_000e6);
    }

    function testForkCustodyCollectAndExitGoogleStock0() public onlyFork {
        _checkLifecycle(GOOGL_POOL, 10 ether, 10_000e6);
    }

    function testForkCustodyCollectAndExitNvidiaStock1() public onlyFork {
        _checkLifecycle(NVDA_POOL, 10_000e6, 10 ether);
    }

    function testForkGoogleActualSwapFeesAndMovedPrincipal() public onlyFork {
        PoolKey memory key = router.getPoolKey(GOOGL_POOL);
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        int24 center = _centerTick(GOOGL_POOL, key.tickSpacing);
        uint256 tokenId =
            _openFor(user, GOOGL_POOL, 10 ether, 10_000e6, center - 1200, center + 1200);
        ValariRouterV3.PositionView memory initial = router.getPosition(tokenId);

        // Both directions earn real swap fees; actual deployed fee/protocol settings apply.
        _swapToTick(GOOGL_POOL, true, center - key.tickSpacing);
        ValariRouterV3.PositionView memory afterFirstSwap = router.getPosition(tokenId);
        assertGt(afterFirstSwap.amount0, initial.amount0);
        assertLt(afterFirstSwap.amount1, initial.amount1);
        assertGt(afterFirstSwap.fees0, 100);
        assertEq(afterFirstSwap.fees1, 0);
        _swapToTick(GOOGL_POOL, false, center + key.tickSpacing);
        ValariRouterV3.PositionView memory beforeCollect = router.getPosition(tokenId);
        assertTrue(beforeCollect.inRange);
        assertGt(beforeCollect.fees0, 100);
        assertGt(beforeCollect.fees1, 100);
        uint256[10] memory balances = _balances(token0, token1);
        vm.prank(user);
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp + 300);
        assertEq(collected.principal0, 0);
        assertEq(collected.principal1, 0);
        assertEq(collected.fees0, beforeCollect.fees0);
        assertEq(collected.fees1, beforeCollect.fees1);
        _assertPayout(token0, token1, collected, balances, beforeCollect);
        ValariRouterV3.PositionView memory afterCollect = router.getPosition(tokenId);
        assertEq(afterCollect.liquidity, initial.liquidity);
        assertEq(afterCollect.amount0, beforeCollect.amount0);
        assertEq(afterCollect.amount1, beforeCollect.amount1);
        assertEq(afterCollect.fees0, 0);
        assertEq(afterCollect.fees1, 0);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), address(router));

        _swapToTick(GOOGL_POOL, true, center - 2 * key.tickSpacing);
        ValariRouterV3.PositionView memory beforeExit = router.getPosition(tokenId);
        assertGt(beforeExit.amount0, initial.amount0);
        assertLt(beforeExit.amount1, initial.amount1);
        assertGt(beforeExit.fees0, 100);
        balances = _balances(token0, token1);
        vm.prank(user);
        ValariRouterV3.Payout memory exited = router.exitPosition(
            tokenId, uint128(beforeExit.amount0), uint128(beforeExit.amount1), block.timestamp + 300
        );
        assertEq(exited.principal0, beforeExit.amount0);
        assertEq(exited.principal1, beforeExit.amount1);
        assertEq(exited.fees0, beforeExit.fees0);
        assertEq(exited.fees1, beforeExit.fees1);
        _assertPayout(token0, token1, exited, balances, beforeExit);
        assertTrue(router.getPosition(tokenId).closed);
        assertFalse(router.getPosition(tokenId).exists);
        _withdrawTreasuryCommissions(token0, token1);
        emit log_named_uint("Robinhood swap lifecycle fork block", block.number);
        emit log_named_uint("Trading currency0 fees collected", collected.fees0 + exited.fees0);
        emit log_named_uint("Trading currency1 fees collected", collected.fees1 + exited.fees1);
    }

    function testForkNvidiaOutOfRangeFeesAndStaleExit() public onlyFork {
        PoolKey memory key = router.getPoolKey(NVDA_POOL);
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        int24 center = _centerTick(NVDA_POOL, key.tickSpacing);
        int24 lower = center - 2 * key.tickSpacing;
        int24 upper = center + 2 * key.tickSpacing;
        // Ensure another active position can receive donations after the narrow LP is crossed.
        uint256 backgroundId =
            _openFor(outsider, NVDA_POOL, 10_000e6, 10 ether, center - 1200, center + 1200);
        uint256 tokenId = _openFor(user, NVDA_POOL, 10_000e6, 10 ether, lower, upper);
        ValariRouterV3.PositionView memory initial = router.getPosition(tokenId);
        assertTrue(initial.inRange);
        assertGt(initial.amount1, 0);
        _swapToTick(NVDA_POOL, true, lower - key.tickSpacing);
        ValariRouterV3.PositionView memory crossed = router.getPosition(tokenId);
        assertFalse(crossed.inRange);
        assertLt(crossed.sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower));
        assertGt(crossed.amount0, initial.amount0);
        assertEq(crossed.amount1, 0);
        assertGt(crossed.fees0, 100);
        assertEq(crossed.fees1, 0);

        // The pre-trade currency1 minimum is no longer attainable. A failed exit is atomic.
        uint256[10] memory balances = _balances(token0, token1);
        vm.prank(user);
        vm.expectRevert(ValariRouterV3.InsufficientProceeds.selector);
        router.exitPosition(
            tokenId, uint128(initial.amount0), uint128(initial.amount1), block.timestamp + 300
        );
        ValariRouterV3.PositionView memory afterFailedExit = router.getPosition(tokenId);
        assertTrue(afterFailedExit.exists);
        assertFalse(afterFailedExit.closed);
        assertEq(afterFailedExit.liquidity, initial.liquidity);
        assertEq(afterFailedExit.fees0, crossed.fees0);
        assertEq(afterFailedExit.fees1, crossed.fees1);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), address(router));
        assertEq(token0.balanceOf(user), balances[0]);
        assertEq(token1.balanceOf(user), balances[1]);
        assertEq(token0.balanceOf(treasury), balances[2]);
        assertEq(token1.balanceOf(treasury), balances[3]);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);

        ValariRouterV3.PositionView memory backgroundBefore = router.getPosition(backgroundId);
        assertTrue(backgroundBefore.inRange);
        _donate(key, 1_000e6, 1 ether);
        ValariRouterV3.PositionView memory backgroundAfter = router.getPosition(backgroundId);
        assertGt(backgroundAfter.fees0, backgroundBefore.fees0);
        assertGt(backgroundAfter.fees1, backgroundBefore.fees1);
        ValariRouterV3.PositionView memory beforeExit = router.getPosition(tokenId);
        assertEq(beforeExit.fees0, crossed.fees0, "Out-of-range LP earns no extra currency0 fees");
        assertEq(beforeExit.fees1, crossed.fees1, "Out-of-range LP earns no extra currency1 fees");
        assertEq(beforeExit.amount0, crossed.amount0);
        assertEq(beforeExit.amount1, 0);
        balances = _balances(token0, token1);
        vm.prank(user);
        ValariRouterV3.Payout memory exited =
            router.exitPosition(tokenId, uint128(beforeExit.amount0), 0, block.timestamp + 300);
        assertEq(exited.principal0, beforeExit.amount0);
        assertEq(exited.principal1, 0);
        assertEq(exited.fees0, beforeExit.fees0);
        assertEq(exited.fees1, beforeExit.fees1);
        _assertPayout(token0, token1, exited, balances, beforeExit);
        assertTrue(router.getPosition(tokenId).closed);
        assertFalse(router.getPosition(tokenId).exists);
        assertEq(router.getPosition(backgroundId).liquidity, backgroundBefore.liquidity);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(backgroundId), address(router));
        (ValariRouterV3.PositionView[] memory positions,) = router.getUserPositions(user, 0, 100);
        assertEq(positions.length, 0);
        (positions,) = router.getUserPositions(outsider, 0, 100);
        assertEq(positions.length, 1);
        assertEq(positions[0].tokenId, backgroundId);
        _withdrawTreasuryCommissions(token0, token1);
        emit log_named_uint("Robinhood range crossing fork block", block.number);
        emit log_named_uint("Out-of-range USDG principal", exited.principal0);
        emit log_named_uint("Out-of-range USDG fees", exited.fees0);
    }
}

/// @notice The V3 exit paths on deployed tokens: eject, payout to another address, and the
/// deposit switch. Kept in its own contract so it does not disturb the lifecycle suite's
/// compilation, which sits close to the via-IR stack limit.
contract ValariRouterV3ForkExitPathsTest is ValariRouterV3ForkBase {
    function testForkEjectedPositionExitsDirectlyOnUniswap() public onlyFork {
        PoolKey memory key = router.getPoolKey(GOOGL_POOL);
        int24 center = _centerTick(GOOGL_POOL, key.tickSpacing);
        uint256 tokenId =
            _openFor(user, GOOGL_POOL, 10 ether, 10_000e6, center - 1200, center + 1200);
        _donate(key, 1 ether, 0);
        ValariRouterV3.PositionView memory held = router.getPosition(tokenId);
        assertGt(held.fees0, 0);

        // Eject collects the fees realized so far on the way out: the net fees reach the
        // depositor and the commission is credited, as it would be on an ordinary collection.
        uint256 stockBefore = IERC20(GOOGL).balanceOf(user);
        uint256 usdgBefore = IERC20(USDG).balanceOf(user);
        _ejectToDepositor(tokenId, held.liquidity);
        assertEq(IERC20(GOOGL).balanceOf(user) - stockBefore, held.netFees0, "net fees at eject");
        assertEq(IERC20(USDG).balanceOf(user) - usdgBefore, held.netFees1);
        assertEq(router.totalClaimableCommission(GOOGL), held.commission0);
        assertEq(IERC20(GOOGL).balanceOf(address(router)), held.commission0);
        assertEq(IERC20(USDG).balanceOf(address(router)), held.commission1);

        // The holder burns on the deployed PositionManager and receives the principal, uncharged.
        stockBefore = IERC20(GOOGL).balanceOf(user);
        usdgBefore = IERC20(USDG).balanceOf(user);
        _burnDirectly(user, tokenId, key, uint128(held.amount0), uint128(held.amount1));
        assertEq(IERC20(GOOGL).balanceOf(user) - stockBefore, held.amount0, "principal only");
        assertEq(IERC20(USDG).balanceOf(user) - usdgBefore, held.amount1);
    }

    function _ejectToDepositor(uint256 tokenId, uint128 liquidity) internal {
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.EjectDisabled.selector, GOOGL_POOL));
        vm.prank(user);
        router.ejectPosition(tokenId, user);

        router.setEjectEnabled(GOOGL_POOL, true);
        vm.expectRevert(ValariRouterV3.NotPositionOwner.selector);
        vm.prank(outsider);
        router.ejectPosition(tokenId, outsider);
        vm.prank(user);
        router.ejectPosition(tokenId, user);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), user);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        ValariRouterV3.PositionView memory ejected = router.getPosition(tokenId);
        assertTrue(ejected.closed);
        assertEq(ejected.nftOwner, user);
    }

    function testForkBeneficiaryIsPaidAtAnotherAddressAndDepositsCanBeStopped() public onlyFork {
        PoolKey memory key = router.getPoolKey(GOOGL_POOL);
        int24 center = _centerTick(GOOGL_POOL, key.tickSpacing);
        uint256 tokenId =
            _openFor(user, GOOGL_POOL, 10 ether, 10_000e6, center - 1200, center + 1200);
        _donate(key, 1 ether, 0);
        ValariRouterV3.PositionView memory held = router.getPosition(tokenId);
        uint256 userStock = IERC20(GOOGL).balanceOf(user);
        uint256 otherStock = IERC20(GOOGL).balanceOf(outsider);

        vm.prank(user);
        ValariRouterV3.Payout memory collected =
            router.collectFeesTo(tokenId, outsider, block.timestamp + 300);
        assertEq(collected.fees0, held.fees0);
        assertEq(IERC20(GOOGL).balanceOf(outsider) - otherStock, held.netFees0);

        router.setDepositsDisabled(GOOGL_POOL, true);
        _expectDepositRefused(center - 1200, center + 1200);

        // The stopped pool still pays out, here to the address the beneficiary names.
        held = router.getPosition(tokenId);
        otherStock = IERC20(GOOGL).balanceOf(outsider);
        uint256 otherUsdg = IERC20(USDG).balanceOf(outsider);
        vm.prank(user);
        ValariRouterV3.Payout memory exited = router.exitPositionTo(
            tokenId, outsider, uint128(held.amount0), uint128(held.amount1), block.timestamp + 300
        );
        assertEq(exited.principal0, held.amount0);
        assertEq(exited.principal1, held.amount1);
        assertEq(IERC20(GOOGL).balanceOf(outsider) - otherStock, exited.amount0);
        assertEq(IERC20(USDG).balanceOf(outsider) - otherUsdg, exited.amount1);
        assertEq(IERC20(GOOGL).balanceOf(user), userStock);
        assertEq(
            router.claimableCommission(treasury, GOOGL), collected.commission0 + exited.commission0
        );
    }

    function _burnDirectly(
        address holder,
        uint256 tokenId,
        PoolKey memory key,
        uint128 min0,
        uint128 min1
    ) internal {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, min0, min1, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, holder);
        vm.prank(holder);
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)), params
            ),
            block.timestamp + 300
        );
    }

    function _expectDepositRefused(int24 lower, int24 upper) internal {
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(GOOGL_POOL, 1 ether, 1_000e6, lower, upper);
        deal(GOOGL, outsider, 1 ether);
        deal(USDG, outsider, 1_000e6);
        vm.startPrank(outsider);
        IERC20(GOOGL).approve(address(router), 1 ether);
        IERC20(USDG).approve(address(router), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouterV3.DepositsDisabled.selector, GOOGL_POOL)
        );
        router.openPosition(
            GOOGL_POOL,
            1 ether,
            1_000e6,
            lower,
            upper,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp + 300
        );
        vm.stopPrank();
        assertEq(IERC20(GOOGL).balanceOf(outsider), 1 ether);
        assertEq(IERC20(USDG).balanceOf(outsider), 1_000e6);
    }
}
