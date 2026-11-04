// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ValariRouter} from "../src/ValariRouter.sol";

/// @dev ERC20 with opt-in transfer tax and callback to exercise funding defenses.
contract RouterTestToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint256 public transferFeeBps;
    mapping(address => bool) public blockedRecipient;

    error RecipientBlocked(address recipient);
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function mint(address recipient, uint256 amount) external {
        totalSupply += amount;
        balanceOf[recipient] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function setTransferFee(uint256 bps) external {
        transferFeeBps = bps;
    }

    function setBlockedRecipient(address recipient, bool blocked) external {
        blockedRecipient[recipient] = blocked;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (blockedRecipient[to]) revert RecipientBlocked(to);
        if (callbackTarget != address(0) && !callbackAttempted) {
            callbackAttempted = true;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        uint256 fee = amount * transferFeeBps / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}

/// @notice Integration tests against real Uniswap v4 core, periphery and Permit2.
contract ValariRouterTest is Test, DeployPermit2, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    PoolManager internal manager;
    PositionManager internal positionManager;
    StateView internal stateView;
    IAllowanceTransfer internal permit2;
    ValariRouter internal router;
    RouterTestToken internal token0;
    RouterTestToken internal token1;
    PoolKey internal key;
    bytes32 internal poolId;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeRecipient = makeAddr("feeRecipient");
    uint256 internal constant INITIAL_BALANCE = 1_000_000 ether;
    uint128 internal constant BUDGET = 100 ether;
    uint160 internal constant SQRT_ONE = uint160(1 << 96);

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager = new PositionManager(
            manager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        stateView = new StateView(manager);
        RouterTestToken first = new RouterTestToken();
        RouterTestToken second = new RouterTestToken();
        (token0, token1) = address(first) < address(second) ? (first, second) : (second, first);
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, SQRT_ONE);
        poolId = keccak256(abi.encode(key));
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        router = new ValariRouter(positionManager, stateView, address(token0), pools);
        assertEq(router.feeRecipient(), address(this));
        router.setFeeRecipient(feeRecipient);
        _fund(alice);
        _fund(bob);
        token0.mint(address(this), INITIAL_BALANCE);
        token1.mint(address(this), INITIAL_BALANCE);
    }

    function _fund(address user) internal {
        token0.mint(user, INITIAL_BALANCE);
        token1.mint(user, INITIAL_BALANCE);
        vm.startPrank(user);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _open(address user, uint128 budget0, uint128 budget1, int24 lower, int24 upper)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 spent0, uint256 spent1)
    {
        ValariRouter.DepositQuote memory quote =
            router.previewDeposit(poolId, budget0, budget1, lower, upper);
        vm.prank(user);
        return router.openPosition(
            poolId, budget0, budget1, lower, upper, quote.liquidity, block.timestamp + 1 hours
        );
    }

    function _assertNoAllowances() internal view {
        assertEq(token0.allowance(address(router), address(permit2)), 0);
        assertEq(token1.allowance(address(router), address(permit2)), 0);
        (uint160 allowance0,,) =
            permit2.allowance(address(router), address(token0), address(positionManager));
        (uint160 allowance1,,) =
            permit2.allowance(address(router), address(token1), address(positionManager));
        assertEq(allowance0, 0);
        assertEq(allowance1, 0);
    }

    function _assertCommissionBacking(uint256 dust0, uint256 dust1) internal view {
        assertEq(
            token0.balanceOf(address(router)),
            dust0 + router.totalClaimableCommission(address(token0))
        );
        assertEq(
            token1.balanceOf(address(router)),
            dust1 + router.totalClaimableCommission(address(token1))
        );
    }

    function testOpenTwoSidedPositionCustodiedForUserAndRefundsUnspentBudgets() public {
        ValariRouter.DepositQuote memory quote =
            router.previewDeposit(poolId, BUDGET, 2 * BUDGET, -600, 600);
        (uint256 tokenId, uint128 liquidity, uint256 spent0, uint256 spent1) =
            _open(alice, BUDGET, 2 * BUDGET, -600, 600);

        assertEq(positionManager.ownerOf(tokenId), address(router));
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        assertEq(liquidity, quote.liquidity);
        assertLe(spent0, BUDGET);
        assertLt(spent1, 2 * BUDGET);
        assertEq(INITIAL_BALANCE - token0.balanceOf(alice), spent0);
        assertEq(INITIAL_BALANCE - token1.balanceOf(alice), spent1);
        _assertCommissionBacking(0, 0);
        assertEq(router.positionCount(), 1);
        assertEq(router.depositCount(alice), 1);
        _assertNoAllowances();

        ValariRouter.PositionView memory position = router.getPosition(tokenId);
        assertTrue(position.exists);
        assertTrue(position.inRange);
        assertEq(position.owner, alice);
        assertEq(position.nftOwner, address(router));
        assertFalse(position.closed);
        assertEq(position.depositor, alice);
        assertEq(position.poolId, poolId);
        assertEq(position.liquidity, liquidity);
        assertEq(position.initialLiquidity, liquidity);
        assertEq(position.amount0Deposited, spent0);
        assertEq(position.amount1Deposited, spent1);
        assertEq(position.openedAt, block.timestamp);
        assertEq(position.tickLower, -600);
        assertEq(position.tickUpper, 600);
        assertEq(position.sqrtPriceX96, SQRT_ONE);
        assertApproxEqAbs(position.amount0, spent0, 1);
        assertApproxEqAbs(position.amount1, spent1, 1);
        assertEq(position.fees0, 0);
        assertEq(position.fees1, 0);
    }

    function testOneSidedToken0AboveCurrentPrice() public {
        (uint256 tokenId,, uint256 spent0, uint256 spent1) = _open(alice, BUDGET, 0, 600, 1200);
        assertGt(spent0, 0);
        assertEq(spent1, 0);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE);
        assertFalse(router.getPosition(tokenId).inRange);
        _assertNoAllowances();
    }

    function testOneSidedToken1BelowCurrentPrice() public {
        (uint256 tokenId,, uint256 spent0, uint256 spent1) = _open(alice, 0, BUDGET, -1200, -600);
        assertEq(spent0, 0);
        assertGt(spent1, 0);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertFalse(router.getPosition(tokenId).inRange);
        _assertNoAllowances();
    }

    function testExistingRouterDustCannotBeSpentOrRefundedToDepositor() public {
        token0.mint(address(router), 23 ether);
        token1.mint(address(router), 19 ether);
        (,, uint256 spent0, uint256 spent1) = _open(alice, BUDGET, 2 * BUDGET, -600, 600);
        _assertCommissionBacking(23 ether, 19 ether);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - spent0);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE - spent1);
        _assertNoAllowances();
    }

    function testRejectsUnknownPool() public {
        vm.expectRevert();
        router.previewDeposit(bytes32(uint256(42)), BUDGET, BUDGET, -600, 600);
        vm.expectRevert();
        vm.prank(alice);
        router.openPosition(bytes32(uint256(42)), BUDGET, BUDGET, -600, 600, 1, block.timestamp);
    }

    function testRejectsInvalidTickRanges() public {
        vm.expectRevert();
        router.previewDeposit(poolId, BUDGET, BUDGET, 600, -600);
        vm.expectRevert();
        router.previewDeposit(poolId, BUDGET, BUDGET, 600, 600);
        vm.expectRevert();
        router.previewDeposit(poolId, BUDGET, BUDGET, -599, 600);
        vm.expectRevert();
        router.previewDeposit(poolId, BUDGET, BUDGET, -600, 599);
        vm.expectRevert();
        router.previewDeposit(poolId, BUDGET, BUDGET, -887_280, 600);
        vm.expectRevert();
        router.previewDeposit(poolId, BUDGET, BUDGET, -600, 887_280);
    }

    function testRejectsZeroFundingAndFundingWrongSide() public {
        vm.expectRevert();
        router.previewDeposit(poolId, 0, 0, -600, 600);
        vm.expectRevert();
        router.previewDeposit(poolId, 0, BUDGET, 600, 1200);
        vm.expectRevert();
        router.previewDeposit(poolId, BUDGET, 0, -1200, -600);
    }

    function testRejectsZeroMinimumLiquidity() public {
        vm.expectRevert();
        vm.prank(alice);
        router.openPosition(poolId, BUDGET, BUDGET, -600, 600, 0, block.timestamp);
    }

    function testRejectsExpiredDeadlineWithoutMovingFunds() public {
        vm.expectRevert();
        vm.prank(alice);
        router.openPosition(poolId, BUDGET, BUDGET, -600, 600, 1, block.timestamp - 1);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE);
        assertEq(router.positionCount(), 0);
    }

    function testEnforcesMinimumLiquidityWithoutMovingFunds() public {
        ValariRouter.DepositQuote memory quote =
            router.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        vm.expectRevert();
        vm.prank(alice);
        router.openPosition(poolId, BUDGET, BUDGET, -600, 600, quote.liquidity + 1, block.timestamp);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE);
        assertEq(router.positionCount(), 0);
    }

    function testFeeOnTransferFundingRevertsAtomically() public {
        token0.setTransferFee(100);
        vm.expectRevert();
        vm.prank(alice);
        router.openPosition(poolId, BUDGET, BUDGET, -600, 600, 1, block.timestamp);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(router.positionCount(), 0);
        _assertNoAllowances();
    }

    function testFundingCallbackCannotReenter() public {
        token0.setCallback(
            address(router),
            abi.encodeCall(
                ValariRouter.openPosition,
                (poolId, BUDGET, BUDGET, int24(-600), int24(600), uint128(1), block.timestamp)
            )
        );
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        assertTrue(token0.callbackAttempted());
        assertFalse(token0.callbackSucceeded());
        assertEq(token0.callbackResult(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertEq(router.positionCount(), 1);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        _assertNoAllowances();
    }

    function testConstructorRejectsEmptyOversizedAndDuplicateStockCatalogs() public {
        PoolKey[] memory pools = new PoolKey[](0);
        vm.expectRevert(ValariRouter.InvalidConfiguration.selector);
        new ValariRouter(positionManager, stateView, address(token0), pools);
        pools = new PoolKey[](101);
        vm.expectRevert(ValariRouter.InvalidConfiguration.selector);
        new ValariRouter(positionManager, stateView, address(token0), pools);
        pools = new PoolKey[](2);
        pools[0] = key;
        pools[1] = key;
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouter.DuplicateStock.selector, address(token1))
        );
        new ValariRouter(positionManager, stateView, address(token0), pools);

        pools[1].fee = 500;
        manager.initialize(pools[1], SQRT_ONE);
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouter.DuplicateStock.selector, address(token1))
        );
        new ValariRouter(positionManager, stateView, address(token0), pools);
    }

    function testConstructorRejectsWrongUsdTokenAndMismatchedStateView() public {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        RouterTestToken unrelated = new RouterTestToken();
        vm.expectRevert(abi.encodeWithSelector(ValariRouter.InvalidPool.selector, poolId));
        new ValariRouter(positionManager, stateView, address(unrelated), pools);

        StateView unrelatedView = new StateView(new PoolManager(address(this)));
        vm.expectRevert(ValariRouter.InvalidConfiguration.selector);
        new ValariRouter(positionManager, unrelatedView, address(token0), pools);
    }

    function testConstructorRejectsUninitializedHookedAndUnsortedPools() public {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        pools[0].fee = 500;
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouter.InvalidPool.selector, keccak256(abi.encode(pools[0]))
            )
        );
        new ValariRouter(positionManager, stateView, address(token0), pools);

        pools[0] = key;
        pools[0].hooks = IHooks(address(0x1234));
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouter.InvalidPool.selector, keccak256(abi.encode(pools[0]))
            )
        );
        new ValariRouter(positionManager, stateView, address(token0), pools);

        pools[0] = key;
        pools[0].currency0 = key.currency1;
        pools[0].currency1 = key.currency0;
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouter.InvalidPool.selector, keccak256(abi.encode(pools[0]))
            )
        );
        new ValariRouter(positionManager, stateView, address(token0), pools);
    }

    function testConstructorSupportsUsdgAsEitherCurrency() public {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        ValariRouter reversed = new ValariRouter(positionManager, stateView, address(token1), pools);
        assertEq(reversed.usdg(), address(token1));
        assertEq(reversed.stockPoolId(address(token0)), poolId);
        assertEq(router.usdg(), address(token0));
        assertEq(router.stockPoolId(address(token1)), poolId);
    }

    function testTickLowerInclusiveAndTickUpperExclusiveAtExactBoundary() public {
        (uint256 lowerBoundary,,,) = _open(alice, BUDGET, 0, 0, 600);
        (uint256 upperBoundary,,,) = _open(alice, 0, BUDGET, -600, 0);
        ValariRouter.PositionView memory lower = router.getPosition(lowerBoundary);
        ValariRouter.PositionView memory upper = router.getPosition(upperBoundary);
        assertTrue(lower.inRange);
        assertFalse(upper.inRange);
        assertGt(lower.amount0, 0);
        assertEq(lower.amount1, 0);
        assertEq(upper.amount0, 0);
        assertGt(upper.amount1, 0);
    }

    function testAsymmetricRawAmountsAtStockUsdPriceScale() public {
        key.fee = 500;
        manager.initialize(key, TickMath.getSqrtPriceAtTick(-276_360));
        poolId = keccak256(abi.encode(key));
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        router = new ValariRouter(positionManager, stateView, address(token1), pools);
        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();

        uint128 stockBudget = 10_000 ether;
        uint128 usdBudget = 10_000 * 1e6;
        (uint256 tokenId,, uint256 spent0, uint256 spent1) =
            _open(alice, stockBudget, usdBudget, -276_960, -275_760);
        assertGt(spent0, 0);
        assertGt(spent1, 0);
        assertLe(spent0, stockBudget);
        assertLe(spent1, usdBudget);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - spent0);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE - spent1);
        ValariRouter.PositionView memory position = router.getPosition(tokenId);
        assertApproxEqAbs(position.amount0, spent0, 1);
        assertApproxEqAbs(position.amount1, spent1, 1);
        _assertNoAllowances();
    }

    function testTinyBudgetsAndMaximumUsableTickRange() public {
        (uint256 tiny,, uint256 spent0, uint256 spent1) = _open(alice, 1, 1, -60, 60);
        assertGt(router.getPosition(tiny).liquidity, 0);
        assertEq(spent0, 1);
        assertEq(spent1, 1);
        (uint256 wide,,,) = _open(alice, BUDGET, BUDGET, -887_220, 887_220);
        assertTrue(router.getPosition(wide).inRange);
    }

    function testGetterRejectsUnknownPositionAndInvalidPagination() public {
        vm.expectRevert(abi.encodeWithSelector(ValariRouter.UnknownPosition.selector, 42));
        router.getPosition(42);
        vm.expectRevert(ValariRouter.InvalidPageSize.selector);
        router.getUserPositions(alice, 0, 0);
        vm.expectRevert(ValariRouter.InvalidPageSize.selector);
        router.getUserPositions(alice, 0, 101);
        vm.expectRevert(ValariRouter.InvalidOwner.selector);
        router.getUserPositions(address(0), 0, 100);
        (ValariRouter.PositionView[] memory positions, uint256 cursor) =
            router.getUserPositions(alice, type(uint256).max, 100);
        assertEq(positions.length, 0);
        assertEq(cursor, 0);
        assertEq(router.getPoolIds(type(uint256).max, 100).length, 0);
        assertEq(router.getDepositorPositionIds(alice, type(uint256).max, 100).length, 0);
    }

    function testPoolAndDepositorPagination() public {
        (uint256 first,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        (uint256 second,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        _open(bob, BUDGET, BUDGET, -600, 600);
        assertEq(router.poolCount(), 1);
        assertEq(abi.encode(router.getPoolKey(poolId)), abi.encode(key));
        bytes32[] memory ids = router.getPoolIds(0, 100);
        assertEq(ids.length, 1);
        assertEq(ids[0], poolId);
        assertEq(router.getPoolIds(1, 100).length, 0);
        uint256[] memory deposits = router.getDepositorPositionIds(alice, 0, 1);
        assertEq(deposits.length, 1);
        assertEq(deposits[0], first);
        deposits = router.getDepositorPositionIds(alice, 1, 100);
        assertEq(deposits.length, 1);
        assertEq(deposits[0], second);
        assertEq(router.getDepositorPositionIds(alice, 2, 100).length, 0);
        assertEq(router.depositCount(alice), 2);
        assertEq(router.depositCount(bob), 1);
        assertEq(router.positionCount(), 3);
    }

    function testBeneficiaryPaginationFiltersOtherUsersAndClosedPositions() public {
        (uint256 first,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        (uint256 second,,,) = _open(bob, BUDGET, BUDGET, -600, 600);
        (uint256 third,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        (ValariRouter.PositionView[] memory owned, uint256 cursor) =
            router.getUserPositions(bob, 0, 1);
        assertEq(owned.length, 1);
        assertEq(owned[0].tokenId, second);
        assertEq(owned[0].owner, bob);
        assertEq(owned[0].nftOwner, address(router));
        assertEq(cursor, 1);
        (owned, cursor) = router.getUserPositions(bob, cursor, 1);
        assertEq(owned.length, 0);
        assertEq(cursor, router.depositCount(bob));
        (owned, cursor) = router.getUserPositions(alice, 0, 100);
        assertEq(owned.length, 2);
        assertEq(owned[0].tokenId, first);
        assertEq(owned[1].tokenId, third);
        assertEq(cursor, 2);
        vm.prank(alice);
        router.exitPosition(first, 0, 0, block.timestamp);
        (owned, cursor) = router.getUserPositions(alice, 0, 1);
        assertEq(owned.length, 0);
        assertEq(cursor, 1);
        (owned, cursor) = router.getUserPositions(alice, cursor, 1);
        assertEq(owned.length, 1);
        assertEq(owned[0].tokenId, third);
        assertEq(cursor, 2);
        assertEq(router.getPosition(first).owner, alice);
        assertEq(router.depositCount(alice), 2);
        assertEq(router.depositCount(bob), 1);
    }

    function testLivePrincipalAndFeesReflectActualSwap() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        ValariRouter.PositionView memory beforeSwap = router.getPosition(tokenId);
        manager.unlock(abi.encode(false, true, uint256(1 ether), uint256(0)));
        ValariRouter.PositionView memory afterSwap = router.getPosition(tokenId);
        assertEq(afterSwap.liquidity, liquidity);
        assertGt(afterSwap.amount0, beforeSwap.amount0);
        assertLt(afterSwap.amount1, beforeSwap.amount1);
        assertLt(afterSwap.sqrtPriceX96, beforeSwap.sqrtPriceX96);
        assertApproxEqAbs(afterSwap.fees0, 0.003 ether, 2);
        assertEq(afterSwap.fees1, 0);
        assertEq(afterSwap.amount0Deposited, beforeSwap.amount0Deposited);
        assertEq(afterSwap.amount1Deposited, beforeSwap.amount1Deposited);
    }

    function testStaleQuoteMinimumLiquidityRevertsAfterRealPriceMove() public {
        _open(alice, BUDGET, BUDGET, -600, 600);
        ValariRouter.DepositQuote memory beforeSwap =
            router.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(false, true, uint256(1 ether), uint256(0)));
        ValariRouter.DepositQuote memory afterSwap =
            router.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        assertLt(afterSwap.liquidity, beforeSwap.liquidity);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouter.LiquidityBelowMinimum.selector,
                afterSwap.liquidity,
                beforeSwap.liquidity
            )
        );
        vm.prank(bob);
        router.openPosition(
            poolId, BUDGET, BUDGET, -600, 600, beforeSwap.liquidity, block.timestamp
        );
        assertEq(token0.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token1.balanceOf(bob), INITIAL_BALANCE);
        assertEq(router.positionCount(), 1);
    }

    function testFeeGrowthWrapUsesUniswapModuloArithmetic() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        uint256 q128 = 1 << 128;
        vm.mockCall(
            address(stateView),
            abi.encodeWithSignature(
                "getPositionInfo(bytes32,address,int24,int24,bytes32)",
                poolId,
                address(positionManager),
                int24(-600),
                int24(600),
                bytes32(tokenId)
            ),
            abi.encode(liquidity, type(uint256).max - q128, uint256(0))
        );
        vm.mockCall(
            address(stateView),
            abi.encodeWithSignature(
                "getFeeGrowthInside(bytes32,int24,int24)", poolId, int24(-600), int24(600)
            ),
            abi.encode(q128, uint256(0))
        );
        ValariRouter.PositionView memory position = router.getPosition(tokenId);
        assertEq(position.fees0, 2 * uint256(liquidity));
        assertEq(position.fees1, 0);
    }

    function testCollectFeesAccruesTenPercentAndPreservesAllPrincipal() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        ValariRouter.PositionView memory beforeClaim = router.getPosition(tokenId);
        assertApproxEqAbs(beforeClaim.fees0, 1 ether, 1);
        assertApproxEqAbs(beforeClaim.fees1, 2 ether, 1);
        uint256 userBefore0 = token0.balanceOf(alice);
        uint256 userBefore1 = token1.balanceOf(alice);
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        ValariRouter.PositionView memory afterClaim = router.getPosition(tokenId);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), beforeClaim.fees0 / 10);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), beforeClaim.fees1 / 10);
        assertEq(token0.balanceOf(feeRecipient), 0);
        assertEq(token1.balanceOf(feeRecipient), 0);
        assertEq(token0.balanceOf(alice) - userBefore0, beforeClaim.fees0 - beforeClaim.fees0 / 10);
        assertEq(token1.balanceOf(alice) - userBefore1, beforeClaim.fees1 - beforeClaim.fees1 / 10);
        assertEq(afterClaim.liquidity, liquidity);
        assertEq(afterClaim.amount0, beforeClaim.amount0);
        assertEq(afterClaim.amount1, beforeClaim.amount1);
        assertEq(afterClaim.fees0, 0);
        assertEq(afterClaim.fees1, 0);
        assertFalse(afterClaim.closed);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        _assertCommissionBacking(0, 0);
        _assertNoAllowances();
    }

    function testExitReturnsFullPrincipalPlusNetFeesAndRetainsDepositHistory() public {
        (uint256 tokenId, uint128 liquidity, uint256 spent0, uint256 spent1) =
            _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        ValariRouter.PositionView memory beforeExit = router.getPosition(tokenId);
        uint256 userBefore0 = token0.balanceOf(alice);
        uint256 userBefore1 = token1.balanceOf(alice);
        vm.prank(alice);
        router.exitPosition(
            tokenId, uint128(beforeExit.amount0), uint128(beforeExit.amount1), block.timestamp
        );
        ValariRouter.PositionView memory position = router.getPosition(tokenId);
        assertFalse(position.exists);
        assertTrue(position.closed);
        assertEq(position.owner, alice);
        assertEq(position.nftOwner, address(0));
        assertEq(position.liquidity, 0);
        assertEq(position.amount0, 0);
        assertEq(position.amount1, 0);
        assertEq(position.fees0, 0);
        assertEq(position.fees1, 0);
        assertEq(position.depositor, alice);
        assertEq(position.initialLiquidity, liquidity);
        assertEq(position.amount0Deposited, spent0);
        assertEq(position.amount1Deposited, spent1);
        assertEq(router.depositCount(alice), 1);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), beforeExit.fees0 / 10);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), beforeExit.fees1 / 10);
        assertEq(
            token0.balanceOf(alice) - userBefore0,
            beforeExit.amount0 + beforeExit.fees0 - beforeExit.fees0 / 10
        );
        assertEq(
            token1.balanceOf(alice) - userBefore1,
            beforeExit.amount1 + beforeExit.fees1 - beforeExit.fees1 / 10
        );
        _assertCommissionBacking(0, 0);
        (ValariRouter.PositionView[] memory owned, uint256 cursor) =
            router.getUserPositions(alice, 0, 100);
        assertEq(owned.length, 0);
        assertEq(cursor, 1);
        _assertNoAllowances();
    }

    function testDirectNftTransferAndDirectPositionManagerWithdrawalAreBlocked() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        vm.expectRevert();
        vm.prank(alice);
        positionManager.transferFrom(address(router), alice, tokenId);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, alice);
        vm.expectRevert();
        vm.prank(alice);
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)),
                params
            ),
            block.timestamp
        );
        assertEq(positionManager.ownerOf(tokenId), address(router));
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        assertEq(router.getPosition(tokenId).owner, alice);
    }

    function testNoCommissionOnDepositZeroFeeCollectionOrPrincipalOnlyExit() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        assertEq(router.COMMISSION_BPS(), 1000);
        assertEq(router.BPS_DENOMINATOR(), 10_000);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), 0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), 0);
        ValariRouter.PositionView memory position = router.getPosition(tokenId);
        uint256 balance0 = token0.balanceOf(alice);
        uint256 balance1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouter.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        _assertPayout(collected, 0, 0, 0, 0, 0, 0);
        assertEq(token0.balanceOf(alice), balance0);
        assertEq(token1.balanceOf(alice), balance1);
        assertEq(router.getPosition(tokenId).liquidity, position.liquidity);
        vm.prank(alice);
        ValariRouter.Payout memory exited = router.exitPosition(
            tokenId, uint128(position.amount0), uint128(position.amount1), block.timestamp
        );
        _assertPayout(exited, position.amount0, position.amount1, 0, 0, 0, 0);
        assertEq(token0.balanceOf(alice), balance0 + position.amount0);
        assertEq(token1.balanceOf(alice), balance1 + position.amount1);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), 0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), 0);
    }

    function testRepeatedCollectionDoesNotDoubleChargeOrPayFees() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        ValariRouter.PositionView memory position = router.getPosition(tokenId);
        vm.prank(alice);
        ValariRouter.Payout memory first = router.collectFees(tokenId, block.timestamp);
        _assertPayout(
            first, 0, 0, position.fees0, position.fees1, position.fees0 / 10, position.fees1 / 10
        );
        uint256 balance0 = token0.balanceOf(alice);
        uint256 balance1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouter.Payout memory second = router.collectFees(tokenId, block.timestamp);
        _assertPayout(second, 0, 0, 0, 0, 0, 0);
        assertEq(token0.balanceOf(alice), balance0);
        assertEq(token1.balanceOf(alice), balance1);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), first.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), first.commission1);
        ValariRouter.PositionView memory afterClaim = router.getPosition(tokenId);
        assertEq(afterClaim.feesCollected0, position.fees0);
        assertEq(afterClaim.feesCollected1, position.fees1);
        assertEq(afterClaim.commissionAccrued0, first.commission0);
        assertEq(afterClaim.commissionAccrued1, first.commission1);
    }

    function testTinyRepeatedClaimsCarryCommissionRoundingThroughExit() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        uint256 totalFees0;
        uint256 totalFees1;
        for (uint256 i; i < 8; ++i) {
            manager.unlock(abi.encode(true, false, uint256(7), uint256(9)));
            ValariRouter.PositionView memory pending = router.getPosition(tokenId);
            uint256 cut0 = (totalFees0 + pending.fees0) / 10 - totalFees0 / 10;
            uint256 cut1 = (totalFees1 + pending.fees1) / 10 - totalFees1 / 10;
            assertLt(pending.fees0, 10);
            assertLt(pending.fees1, 10);
            assertEq(pending.commission0, cut0);
            assertEq(pending.commission1, cut1);
            assertEq(pending.netFees0, pending.fees0 - cut0);
            assertEq(pending.netFees1, pending.fees1 - cut1);
            vm.prank(alice);
            ValariRouter.Payout memory paid = router.collectFees(tokenId, block.timestamp);
            _assertPayout(paid, 0, 0, pending.fees0, pending.fees1, cut0, cut1);
            totalFees0 += pending.fees0;
            totalFees1 += pending.fees1;
            assertEq(router.claimableCommission(feeRecipient, address(token0)), totalFees0 / 10);
            assertEq(router.claimableCommission(feeRecipient, address(token1)), totalFees1 / 10);
            ValariRouter.PositionView memory afterClaim = router.getPosition(tokenId);
            assertEq(afterClaim.feesCollected0, totalFees0);
            assertEq(afterClaim.feesCollected1, totalFees1);
            assertEq(afterClaim.commissionAccrued0, totalFees0 / 10);
            assertEq(afterClaim.commissionAccrued1, totalFees1 / 10);
        }
        manager.unlock(abi.encode(true, false, uint256(7), uint256(9)));
        ValariRouter.PositionView memory beforeExit = router.getPosition(tokenId);
        uint256 finalCut0 = (totalFees0 + beforeExit.fees0) / 10 - totalFees0 / 10;
        uint256 finalCut1 = (totalFees1 + beforeExit.fees1) / 10 - totalFees1 / 10;
        vm.prank(alice);
        ValariRouter.Payout memory exited = router.exitPosition(tokenId, 0, 0, block.timestamp);
        _assertPayout(
            exited,
            beforeExit.amount0,
            beforeExit.amount1,
            beforeExit.fees0,
            beforeExit.fees1,
            finalCut0,
            finalCut1
        );
        totalFees0 += beforeExit.fees0;
        totalFees1 += beforeExit.fees1;
        assertEq(router.claimableCommission(feeRecipient, address(token0)), totalFees0 / 10);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), totalFees1 / 10);
        ValariRouter.PositionView memory closed = router.getPosition(tokenId);
        assertEq(closed.feesCollected0, totalFees0);
        assertEq(closed.feesCollected1, totalFees1);
        assertEq(closed.commissionAccrued0, totalFees0 / 10);
        assertEq(closed.commissionAccrued1, totalFees1 / 10);
    }

    function testOnlyBeneficiaryCanCollectOrExitIncludingAgainstContractOwner() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.expectRevert();
        vm.prank(bob);
        router.collectFees(tokenId, block.timestamp);
        vm.expectRevert();
        vm.prank(bob);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        vm.expectRevert();
        router.collectFees(tokenId, block.timestamp);
        vm.expectRevert();
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), 0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), 0);
        assertFalse(router.getPosition(tokenId).closed);
    }

    function testClosedPositionCannotBeCollectedOrExitedAgain() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        uint256 balance0 = token0.balanceOf(alice);
        uint256 balance1 = token1.balanceOf(alice);
        vm.expectRevert();
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        vm.expectRevert();
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(token0.balanceOf(alice), balance0);
        assertEq(token1.balanceOf(alice), balance1);
    }

    function testExpiredCollectAndExitRevertWithoutChangingPosition() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        ValariRouter.PositionView memory beforeAction = router.getPosition(tokenId);
        vm.expectRevert();
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp - 1);
        vm.expectRevert();
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp - 1);
        ValariRouter.PositionView memory afterAction = router.getPosition(tokenId);
        assertEq(afterAction.liquidity, liquidity);
        assertEq(afterAction.fees0, beforeAction.fees0);
        assertEq(afterAction.fees1, beforeAction.fees1);
        assertEq(afterAction.feesCollected0, 0);
        assertEq(afterAction.feesCollected1, 0);
    }

    function testExitMinimumPrincipalRevertsAtomicallyEvenWithEnoughFees() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        ValariRouter.PositionView memory beforeExit = router.getPosition(tokenId);
        uint256 user0 = token0.balanceOf(alice);
        uint256 user1 = token1.balanceOf(alice);
        vm.expectRevert();
        vm.prank(alice);
        router.exitPosition(tokenId, uint128(beforeExit.amount0 + 1), 0, block.timestamp);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        ValariRouter.PositionView memory afterExit = router.getPosition(tokenId);
        assertFalse(afterExit.closed);
        assertEq(afterExit.fees0, beforeExit.fees0);
        assertEq(afterExit.fees1, beforeExit.fees1);
        assertEq(afterExit.feesCollected0, 0);
        assertEq(afterExit.feesCollected1, 0);
        assertEq(token0.balanceOf(alice), user0);
        assertEq(token1.balanceOf(alice), user1);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), 0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), 0);
    }

    function testCollectionAndExitCannotDistributeExistingRouterDust() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        token0.mint(address(router), 23 ether);
        token1.mint(address(router), 19 ether);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        _assertCommissionBacking(23 ether, 19 ether);
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        _assertCommissionBacking(23 ether, 19 ether);
    }

    function testCollectionCallbackCannotReenterExit() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        token0.setCallback(
            address(router),
            abi.encodeCall(
                ValariRouter.exitPosition, (tokenId, uint128(0), uint128(0), block.timestamp)
            )
        );
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        assertTrue(token0.callbackAttempted());
        assertFalse(token0.callbackSucceeded());
        assertEq(token0.callbackResult(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertFalse(router.getPosition(tokenId).closed);
    }

    function testExitCallbackCannotReenterCollection() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        token0.setCallback(
            address(router), abi.encodeCall(ValariRouter.collectFees, (tokenId, block.timestamp))
        );
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertTrue(token0.callbackAttempted());
        assertFalse(token0.callbackSucceeded());
        assertEq(token0.callbackResult(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertTrue(router.getPosition(tokenId).closed);
    }

    function testOwnerAloneCanChangeFeeRecipientAndCannotSetZeroOrRouter() public {
        assertEq(router.owner(), address(this));
        assertEq(router.feeRecipient(), feeRecipient);
        vm.expectRevert();
        vm.prank(alice);
        router.setFeeRecipient(alice);
        vm.expectRevert();
        router.setFeeRecipient(address(0));
        vm.expectRevert();
        router.setFeeRecipient(address(router));
        address replacement = makeAddr("replacement treasury");
        router.setFeeRecipient(replacement);
        assertEq(router.feeRecipient(), replacement);
    }

    function testRecipientChangeRoutesFutureCommissionAndPreservesBeneficiaryPayout() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory first = router.collectFees(tokenId, block.timestamp);
        address replacement = makeAddr("replacement treasury");
        router.setFeeRecipient(replacement);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        uint256 user0 = token0.balanceOf(alice);
        uint256 user1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouter.Payout memory last = router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), first.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), first.commission1);
        assertEq(router.claimableCommission(replacement, address(token0)), last.commission0);
        assertEq(router.claimableCommission(replacement, address(token1)), last.commission1);
        assertEq(token0.balanceOf(alice) - user0, last.amount0);
        assertEq(token1.balanceOf(alice) - user1, last.amount1);
    }

    function testOwnershipTransferRequiresAcceptanceAndDoesNotChangeFeeRecipient() public {
        router.transferOwnership(bob);
        assertEq(router.owner(), address(this));
        assertEq(router.pendingOwner(), bob);
        vm.expectRevert();
        vm.prank(alice);
        router.acceptOwnership();
        vm.prank(bob);
        router.acceptOwnership();
        assertEq(router.owner(), bob);
        assertEq(router.pendingOwner(), address(0));
        assertEq(router.feeRecipient(), feeRecipient);
        vm.expectRevert();
        router.setFeeRecipient(alice);
        vm.prank(bob);
        router.setFeeRecipient(alice);
        assertEq(router.feeRecipient(), alice);
    }

    function testCommissionWithdrawalsSupportPartialFullAndIndependentTokens() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        uint256 half = collected.commission0 / 2;
        uint256 user0 = token0.balanceOf(alice);
        uint256 user1 = token1.balanceOf(alice);
        assertEq(token0.balanceOf(feeRecipient), 0);
        assertEq(token1.balanceOf(feeRecipient), 0);

        vm.prank(feeRecipient);
        router.withdrawCommission(address(token0), feeRecipient, half);
        assertEq(token0.balanceOf(feeRecipient), half);
        assertEq(
            router.claimableCommission(feeRecipient, address(token0)), collected.commission0 - half
        );
        assertEq(router.totalClaimableCommission(address(token0)), collected.commission0 - half);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), collected.commission1);
        assertEq(router.totalClaimableCommission(address(token1)), collected.commission1);
        _assertCommissionBacking(0, 0);

        vm.startPrank(feeRecipient);
        router.withdrawCommission(address(token0), feeRecipient, collected.commission0 - half);
        router.withdrawCommission(address(token1), feeRecipient, collected.commission1);
        vm.stopPrank();
        assertEq(token0.balanceOf(feeRecipient), collected.commission0);
        assertEq(token1.balanceOf(feeRecipient), collected.commission1);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), 0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), 0);
        assertEq(router.totalClaimableCommission(address(token0)), 0);
        assertEq(router.totalClaimableCommission(address(token1)), 0);
        _assertCommissionBacking(0, 0);
        assertEq(token0.balanceOf(alice), user0);
        assertEq(token1.balanceOf(alice), user1);
        ValariRouter.PositionView memory position = router.getPosition(tokenId);
        assertEq(position.commissionAccrued0, collected.commission0);
        assertEq(position.commissionAccrued1, collected.commission1);
        assertEq(position.liquidity, liquidity);
        assertEq(position.nftOwner, address(router));
    }

    function testCommissionWithdrawalsRejectInvalidAmountsDestinationsAndOtherCallers() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        vm.expectRevert(ValariRouter.InsufficientCommission.selector);
        vm.prank(alice);
        router.withdrawCommission(address(token0), alice, collected.commission0);
        vm.expectRevert(ValariRouter.InsufficientCommission.selector);
        router.withdrawCommission(address(token0), address(this), collected.commission0);
        vm.startPrank(feeRecipient);
        vm.expectRevert(ValariRouter.InvalidCommissionWithdrawal.selector);
        router.withdrawCommission(address(0), feeRecipient, collected.commission0);
        vm.expectRevert(ValariRouter.InvalidCommissionWithdrawal.selector);
        router.withdrawCommission(address(token0), address(0), collected.commission0);
        vm.expectRevert(ValariRouter.InvalidCommissionWithdrawal.selector);
        router.withdrawCommission(address(token0), address(router), collected.commission0);
        vm.expectRevert(ValariRouter.InvalidCommissionWithdrawal.selector);
        router.withdrawCommission(address(token0), feeRecipient, 0);
        vm.expectRevert(ValariRouter.InsufficientCommission.selector);
        router.withdrawCommission(address(token0), feeRecipient, collected.commission0 + 1);
        vm.stopPrank();
        assertEq(router.claimableCommission(feeRecipient, address(token0)), collected.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), collected.commission1);
        assertEq(router.totalClaimableCommission(address(token0)), collected.commission0);
        assertEq(router.totalClaimableCommission(address(token1)), collected.commission1);
        assertEq(token0.balanceOf(feeRecipient), 0);
        assertEq(token1.balanceOf(feeRecipient), 0);
        _assertCommissionBacking(0, 0);
    }

    function testRecipientRolloverLeavesOldCreditsWithdrawableOnlyByOriginalRecipient() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory first = router.collectFees(tokenId, block.timestamp);
        address replacement = makeAddr("replacement treasury");
        router.setFeeRecipient(replacement);
        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory last = router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(
            router.totalClaimableCommission(address(token0)), first.commission0 + last.commission0
        );
        assertEq(
            router.totalClaimableCommission(address(token1)), first.commission1 + last.commission1
        );
        vm.expectRevert(ValariRouter.InsufficientCommission.selector);
        vm.prank(replacement);
        router.withdrawCommission(address(token0), replacement, last.commission0 + 1);

        vm.startPrank(feeRecipient);
        router.withdrawCommission(address(token0), feeRecipient, first.commission0);
        router.withdrawCommission(address(token1), feeRecipient, first.commission1);
        vm.stopPrank();
        assertEq(router.claimableCommission(replacement, address(token0)), last.commission0);
        assertEq(router.claimableCommission(replacement, address(token1)), last.commission1);
        assertEq(router.totalClaimableCommission(address(token0)), last.commission0);
        assertEq(router.totalClaimableCommission(address(token1)), last.commission1);
        vm.startPrank(replacement);
        router.withdrawCommission(address(token0), replacement, last.commission0);
        router.withdrawCommission(address(token1), replacement, last.commission1);
        vm.stopPrank();
        assertEq(token0.balanceOf(feeRecipient), first.commission0);
        assertEq(token1.balanceOf(feeRecipient), first.commission1);
        assertEq(token0.balanceOf(replacement), last.commission0);
        assertEq(token1.balanceOf(replacement), last.commission1);
        assertEq(router.totalClaimableCommission(address(token0)), 0);
        assertEq(router.totalClaimableCommission(address(token1)), 0);
        _assertCommissionBacking(0, 0);
    }

    function testBlockedTreasuryCannotBlockCollectionOrPrincipalExitAndCanUseOtherDestination()
        public
    {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        token0.setBlockedRecipient(feeRecipient, true);
        token1.setBlockedRecipient(feeRecipient, true);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        uint256 user0 = token0.balanceOf(alice);
        uint256 user1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouter.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        assertEq(token0.balanceOf(alice) - user0, collected.amount0);
        assertEq(token1.balanceOf(alice) - user1, collected.amount1);
        assertEq(router.getPosition(tokenId).liquidity, liquidity);
        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        ValariRouter.PositionView memory beforeExit = router.getPosition(tokenId);
        user0 = token0.balanceOf(alice);
        user1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouter.Payout memory exited = router.exitPosition(
            tokenId, uint128(beforeExit.amount0), uint128(beforeExit.amount1), block.timestamp
        );
        assertEq(exited.principal0, beforeExit.amount0);
        assertEq(exited.principal1, beforeExit.amount1);
        assertEq(token0.balanceOf(alice) - user0, exited.amount0);
        assertEq(token1.balanceOf(alice) - user1, exited.amount1);
        assertTrue(router.getPosition(tokenId).closed);
        assertEq(
            router.claimableCommission(feeRecipient, address(token0)),
            collected.commission0 + exited.commission0
        );
        assertEq(
            router.claimableCommission(feeRecipient, address(token1)),
            collected.commission1 + exited.commission1
        );
        assertEq(token0.balanceOf(feeRecipient), 0);
        assertEq(token1.balanceOf(feeRecipient), 0);
        _assertCommissionBacking(0, 0);

        address alternate = makeAddr("unblocked treasury destination");
        vm.startPrank(feeRecipient);
        router.withdrawCommission(
            address(token0), alternate, collected.commission0 + exited.commission0
        );
        router.withdrawCommission(
            address(token1), alternate, collected.commission1 + exited.commission1
        );
        vm.stopPrank();
        assertEq(token0.balanceOf(alternate), collected.commission0 + exited.commission0);
        assertEq(token1.balanceOf(alternate), collected.commission1 + exited.commission1);
        assertEq(router.totalClaimableCommission(address(token0)), 0);
        assertEq(router.totalClaimableCommission(address(token1)), 0);
        _assertCommissionBacking(0, 0);
    }

    function testRejectedCommissionTransferPreservesCreditBackingAndPosition() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        token0.setBlockedRecipient(feeRecipient, true);
        vm.expectRevert(
            abi.encodeWithSelector(RouterTestToken.RecipientBlocked.selector, feeRecipient)
        );
        vm.prank(feeRecipient);
        router.withdrawCommission(address(token0), feeRecipient, collected.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), collected.commission0);
        assertEq(router.totalClaimableCommission(address(token0)), collected.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), collected.commission1);
        assertEq(router.totalClaimableCommission(address(token1)), collected.commission1);
        assertEq(token0.balanceOf(feeRecipient), 0);
        assertEq(router.getPosition(tokenId).liquidity, liquidity);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        _assertCommissionBacking(0, 0);
    }

    function testCommissionWithdrawalCallbackCannotReenter() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        token0.setCallback(
            address(router),
            abi.encodeCall(
                ValariRouter.withdrawCommission, (address(token0), feeRecipient, uint256(1))
            )
        );
        vm.prank(feeRecipient);
        router.withdrawCommission(address(token0), feeRecipient, collected.commission0);
        assertTrue(token0.callbackAttempted());
        assertFalse(token0.callbackSucceeded());
        assertEq(token0.callbackResult(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertEq(token0.balanceOf(feeRecipient), collected.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), 0);
        assertEq(router.totalClaimableCommission(address(token0)), 0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), collected.commission1);
        _assertCommissionBacking(0, 0);
    }

    function testLaterDepositsAndExitsCannotSpendOrDistributeAccruedCommission() public {
        (uint256 first,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        token0.mint(address(router), 23 ether);
        token1.mint(address(router), 19 ether);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory collected = router.collectFees(first, block.timestamp);
        (uint256 second,,,) = _open(bob, 2 * BUDGET, BUDGET, -600, 600);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), collected.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), collected.commission1);
        _assertCommissionBacking(23 ether, 19 ether);
        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory exitFirst = router.exitPosition(first, 0, 0, block.timestamp);
        vm.prank(bob);
        ValariRouter.Payout memory exitSecond = router.exitPosition(second, 0, 0, block.timestamp);
        uint256 total0 = collected.commission0 + exitFirst.commission0 + exitSecond.commission0;
        uint256 total1 = collected.commission1 + exitFirst.commission1 + exitSecond.commission1;
        assertEq(router.claimableCommission(feeRecipient, address(token0)), total0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), total1);
        assertEq(router.totalClaimableCommission(address(token0)), total0);
        assertEq(router.totalClaimableCommission(address(token1)), total1);
        _assertCommissionBacking(23 ether, 19 ether);
        vm.startPrank(feeRecipient);
        router.withdrawCommission(address(token0), feeRecipient, total0);
        router.withdrawCommission(address(token1), feeRecipient, total1);
        vm.stopPrank();
        assertEq(token0.balanceOf(feeRecipient), total0);
        assertEq(token1.balanceOf(feeRecipient), total1);
        _assertCommissionBacking(23 ether, 19 ether);
        _assertNoAllowances();
    }

    function testRejectedBeneficiaryPayoutRollsBackNewAccrualAndPreservesEarlierCredit() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouter.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        ValariRouter.PositionView memory beforeAction = router.getPosition(tokenId);
        uint256 user0 = token0.balanceOf(alice);
        uint256 user1 = token1.balanceOf(alice);
        token1.setBlockedRecipient(alice, true);
        vm.expectRevert(abi.encodeWithSelector(RouterTestToken.RecipientBlocked.selector, alice));
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RouterTestToken.RecipientBlocked.selector, alice));
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), collected.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), collected.commission1);
        assertEq(router.totalClaimableCommission(address(token0)), collected.commission0);
        assertEq(router.totalClaimableCommission(address(token1)), collected.commission1);
        assertEq(token0.balanceOf(alice), user0);
        assertEq(token1.balanceOf(alice), user1);
        ValariRouter.PositionView memory afterAction = router.getPosition(tokenId);
        assertEq(afterAction.liquidity, liquidity);
        assertEq(afterAction.fees0, beforeAction.fees0);
        assertEq(afterAction.fees1, beforeAction.fees1);
        assertEq(afterAction.commissionAccrued0, beforeAction.commissionAccrued0);
        assertEq(afterAction.commissionAccrued1, beforeAction.commissionAccrued1);
        assertFalse(afterAction.closed);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        _assertCommissionBacking(0, 0);
    }

    function _assertPayout(
        ValariRouter.Payout memory paid,
        uint256 principal0,
        uint256 principal1,
        uint256 fees0,
        uint256 fees1,
        uint256 commission0,
        uint256 commission1
    ) internal pure {
        assertEq(paid.principal0, principal0);
        assertEq(paid.principal1, principal1);
        assertEq(paid.fees0, fees0);
        assertEq(paid.fees1, fees1);
        assertEq(paid.commission0, commission0);
        assertEq(paid.commission1, commission1);
        assertEq(paid.amount0, principal0 + fees0 - commission0);
        assertEq(paid.amount1, principal1 + fees1 - commission1);
    }

    function testFuzzBudgetsBoundActualSpendingAndKeepNftInRouterCustody(
        uint128 raw0,
        uint128 raw1,
        uint16 rawWidth
    ) public {
        uint128 budget0 = uint128(bound(raw0, 1e12, 10_000 ether));
        uint128 budget1 = uint128(bound(raw1, 1e12, 10_000 ether));
        int24 width = int24(int256(bound(rawWidth, 1, 1000) * 60));
        (uint256 tokenId, uint128 liquidity, uint256 spent0, uint256 spent1) =
            _open(alice, budget0, budget1, -width, width);
        assertGt(liquidity, 0);
        assertLe(spent0, budget0);
        assertLe(spent1, budget1);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - spent0);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE - spent1);
        _assertCommissionBacking(0, 0);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        ValariRouter.PositionView memory position = router.getPosition(tokenId);
        assertApproxEqAbs(position.amount0, spent0, 1);
        assertApproxEqAbs(position.amount1, spent1, 1);
        _assertNoAllowances();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only pool manager");
        (bool donate, bool zeroForOne, uint256 amount0, uint256 amount1) =
            abi.decode(data, (bool, bool, uint256, uint256));
        BalanceDelta delta;
        if (donate) {
            delta = manager.donate(key, amount0, amount1, "");
        } else {
            delta = manager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amount0),
                    sqrtPriceLimitX96: zeroForOne
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            manager.sync(currency);
            RouterTestToken(Currency.unwrap(currency))
                .transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }
}
