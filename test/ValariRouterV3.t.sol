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
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ValariRouterV3} from "../src/ValariRouterV3.sol";
import {RouterTestToken} from "./utils/RouterTestToken.sol";

/// @dev ERC20 with three opt-in faults for one chosen sender. Sticky: it is debited
/// `stickyUnits` less than it sends (rounding in the router's favour). Greedy: it is debited
/// one unit more. Muted: transfers report success and move nothing.
contract StickySenderToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public stickySender;
    uint256 public stickyUnits = 1;
    address public greedySender;
    address public mutedSender;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function setStickySender(address sender) external {
        stickySender = sender;
    }

    function setStickyUnits(uint256 units) external {
        stickyUnits = units;
    }

    function setGreedySender(address sender) external {
        greedySender = sender;
    }

    function setMutedSender(address sender) external {
        mutedSender = sender;
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

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == mutedSender) return;
        if (from == stickySender && amount >= stickyUnits) amount -= stickyUnits;
        balanceOf[from] -= from == greedySender ? amount + 1 : amount;
        balanceOf[to] += amount;
    }
}

/// @dev Donates to any pool, so fees can be created in pools the suite's own callback
/// (which is tied to the first pool) does not reach.
contract PoolDonor is IUnlockCallback {
    PoolManager internal immutable manager;

    constructor(PoolManager manager_) {
        manager = manager_;
    }

    function donate(PoolKey calldata key, uint256 amount0, uint256 amount1) external {
        manager.unlock(abi.encode(key, amount0, amount1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, uint256 amount0, uint256 amount1) =
            abi.decode(data, (PoolKey, uint256, uint256));
        manager.donate(key, amount0, amount1, "");
        _pay(key.currency0, amount0);
        _pay(key.currency1, amount1);
        return "";
    }

    function _pay(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        manager.sync(currency);
        StickySenderToken(Currency.unwrap(currency)).transfer(address(manager), amount);
        manager.settle();
    }
}

/// @dev ERC20 whose approve() calls out once when `hookSender` approves a nonzero amount.
contract ApproveHookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hookSender;
    address public hookTarget;
    bytes public hookData;
    bool public fired;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setHook(address sender, address target, bytes calldata data) external {
        hookSender = sender;
        hookTarget = target;
        hookData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        if (msg.sender == hookSender && amount != 0 && !fired) {
            fired = true;
            (bool ok,) = hookTarget.call(hookData);
            require(ok, "hook failed");
        }
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

/// @notice The ValariRouter integration suite, run against ValariRouterV3, plus the V3 changes.
/// @dev Real Uniswap v4 core, periphery and Permit2.
contract ValariRouterV3Test is Test, DeployPermit2, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    PoolManager internal manager;
    PositionManager internal positionManager;
    StateView internal stateView;
    IAllowanceTransfer internal permit2;
    ValariRouterV3 internal router;
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
        router = new ValariRouterV3(positionManager, stateView, address(token0), pools);
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
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(poolId, budget0, budget1, lower, upper);
        vm.prank(user);
        return router.openPosition(
            poolId,
            budget0,
            budget1,
            lower,
            upper,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp + 1 hours
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
        ValariRouterV3.DepositQuote memory quote =
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

        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
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
        router.openPosition(
            bytes32(uint256(42)),
            BUDGET,
            BUDGET,
            -600,
            600,
            1,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            block.timestamp
        );
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
        router.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            0,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            block.timestamp
        );
    }

    function testRejectsExpiredDeadlineWithoutMovingFunds() public {
        vm.expectRevert();
        vm.prank(alice);
        router.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            1,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            block.timestamp - 1
        );
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE);
        assertEq(router.positionCount(), 0);
    }

    function testEnforcesMinimumLiquidityWithoutMovingFunds() public {
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        vm.expectRevert();
        vm.prank(alice);
        router.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            quote.liquidity + 1,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            block.timestamp
        );
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE);
        assertEq(router.positionCount(), 0);
    }

    function testFeeOnTransferFundingRevertsAtomically() public {
        token0.setTransferFee(100);
        vm.expectRevert();
        vm.prank(alice);
        router.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            1,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            block.timestamp
        );
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
                ValariRouterV3.openPosition,
                (
                    poolId,
                    BUDGET,
                    BUDGET,
                    int24(-600),
                    int24(600),
                    uint128(1),
                    TickMath.MIN_SQRT_PRICE,
                    TickMath.MAX_SQRT_PRICE,
                    block.timestamp
                )
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

    function testConstructorAcceptsEmptyAndFeeTiersAndRejectsOversizedAndDuplicatePools() public {
        PoolKey[] memory pools = new PoolKey[](0);
        ValariRouterV3 empty =
            new ValariRouterV3(positionManager, stateView, address(token0), pools);
        assertEq(empty.poolCount(), 0);
        pools = new PoolKey[](101);
        vm.expectRevert(ValariRouterV3.InvalidConfiguration.selector);
        new ValariRouterV3(positionManager, stateView, address(token0), pools);
        pools = new PoolKey[](2);
        pools[0] = key;
        pools[1] = key;
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.DuplicatePool.selector, poolId));
        new ValariRouterV3(positionManager, stateView, address(token0), pools);

        // A second fee tier for the same stock is a different pool and is accepted.
        pools[1].fee = 500;
        manager.initialize(pools[1], SQRT_ONE);
        ValariRouterV3 tiered =
            new ValariRouterV3(positionManager, stateView, address(token0), pools);
        assertEq(tiered.poolCount(), 2);
        assertEq(tiered.stockPoolCount(address(token1)), 2);
        bytes32[] memory tiers = tiered.getStockPoolIds(address(token1), 0, 100);
        assertEq(tiers[0], poolId);
        assertEq(tiers[1], keccak256(abi.encode(pools[1])));
    }

    function testConstructorRejectsWrongUsdTokenAndMismatchedStateView() public {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        RouterTestToken unrelated = new RouterTestToken();
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, poolId));
        new ValariRouterV3(positionManager, stateView, address(unrelated), pools);

        StateView unrelatedView = new StateView(new PoolManager(address(this)));
        vm.expectRevert(ValariRouterV3.InvalidConfiguration.selector);
        new ValariRouterV3(positionManager, unrelatedView, address(token0), pools);
    }

    function testConstructorRejectsUninitializedHookedAndUnsortedPools() public {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        pools[0].fee = 500;
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.InvalidPool.selector, keccak256(abi.encode(pools[0]))
            )
        );
        new ValariRouterV3(positionManager, stateView, address(token0), pools);

        pools[0] = key;
        pools[0].hooks = IHooks(address(0x1234));
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.InvalidPool.selector, keccak256(abi.encode(pools[0]))
            )
        );
        new ValariRouterV3(positionManager, stateView, address(token0), pools);

        pools[0] = key;
        pools[0].currency0 = key.currency1;
        pools[0].currency1 = key.currency0;
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.InvalidPool.selector, keccak256(abi.encode(pools[0]))
            )
        );
        new ValariRouterV3(positionManager, stateView, address(token0), pools);
    }

    function testConstructorSupportsUsdgAsEitherCurrency() public {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        ValariRouterV3 reversed =
            new ValariRouterV3(positionManager, stateView, address(token1), pools);
        assertEq(reversed.usdg(), address(token1));
        assertEq(reversed.getStockPoolIds(address(token0), 0, 1)[0], poolId);
        assertEq(router.usdg(), address(token0));
        assertEq(router.getStockPoolIds(address(token1), 0, 1)[0], poolId);
    }

    function testTickLowerInclusiveAndTickUpperExclusiveAtExactBoundary() public {
        (uint256 lowerBoundary,,,) = _open(alice, BUDGET, 0, 0, 600);
        (uint256 upperBoundary,,,) = _open(alice, 0, BUDGET, -600, 0);
        ValariRouterV3.PositionView memory lower = router.getPosition(lowerBoundary);
        ValariRouterV3.PositionView memory upper = router.getPosition(upperBoundary);
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
        router = new ValariRouterV3(positionManager, stateView, address(token1), pools);
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
        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
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
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.UnknownPosition.selector, 42));
        router.getPosition(42);
        vm.expectRevert(ValariRouterV3.InvalidPageSize.selector);
        router.getUserPositions(alice, 0, 0);
        vm.expectRevert(ValariRouterV3.InvalidPageSize.selector);
        router.getUserPositions(alice, 0, 101);
        vm.expectRevert(ValariRouterV3.InvalidOwner.selector);
        router.getUserPositions(address(0), 0, 100);
        (ValariRouterV3.PositionView[] memory positions, uint256 cursor) =
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
        (ValariRouterV3.PositionView[] memory owned, uint256 cursor) =
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
        ValariRouterV3.PositionView memory beforeSwap = router.getPosition(tokenId);
        manager.unlock(abi.encode(false, true, uint256(1 ether), uint256(0)));
        ValariRouterV3.PositionView memory afterSwap = router.getPosition(tokenId);
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
        ValariRouterV3.DepositQuote memory beforeSwap =
            router.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(false, true, uint256(1 ether), uint256(0)));
        ValariRouterV3.DepositQuote memory afterSwap =
            router.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        assertLt(afterSwap.liquidity, beforeSwap.liquidity);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.LiquidityBelowMinimum.selector,
                afterSwap.liquidity,
                beforeSwap.liquidity
            )
        );
        vm.prank(bob);
        router.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            beforeSwap.liquidity,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            block.timestamp
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
        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
        assertEq(position.fees0, 2 * uint256(liquidity));
        assertEq(position.fees1, 0);
    }

    function testCollectFeesAccruesTenPercentAndPreservesAllPrincipal() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        ValariRouterV3.PositionView memory beforeClaim = router.getPosition(tokenId);
        assertApproxEqAbs(beforeClaim.fees0, 1 ether, 1);
        assertApproxEqAbs(beforeClaim.fees1, 2 ether, 1);
        uint256 userBefore0 = token0.balanceOf(alice);
        uint256 userBefore1 = token1.balanceOf(alice);
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        ValariRouterV3.PositionView memory afterClaim = router.getPosition(tokenId);
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
        ValariRouterV3.PositionView memory beforeExit = router.getPosition(tokenId);
        uint256 userBefore0 = token0.balanceOf(alice);
        uint256 userBefore1 = token1.balanceOf(alice);
        vm.prank(alice);
        router.exitPosition(
            tokenId, uint128(beforeExit.amount0), uint128(beforeExit.amount1), block.timestamp
        );
        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
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
        (ValariRouterV3.PositionView[] memory owned, uint256 cursor) =
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
        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
        uint256 balance0 = token0.balanceOf(alice);
        uint256 balance1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        _assertPayout(collected, 0, 0, 0, 0, 0, 0);
        assertEq(token0.balanceOf(alice), balance0);
        assertEq(token1.balanceOf(alice), balance1);
        assertEq(router.getPosition(tokenId).liquidity, position.liquidity);
        vm.prank(alice);
        ValariRouterV3.Payout memory exited = router.exitPosition(
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
        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
        vm.prank(alice);
        ValariRouterV3.Payout memory first = router.collectFees(tokenId, block.timestamp);
        _assertPayout(
            first, 0, 0, position.fees0, position.fees1, position.fees0 / 10, position.fees1 / 10
        );
        uint256 balance0 = token0.balanceOf(alice);
        uint256 balance1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouterV3.Payout memory second = router.collectFees(tokenId, block.timestamp);
        _assertPayout(second, 0, 0, 0, 0, 0, 0);
        assertEq(token0.balanceOf(alice), balance0);
        assertEq(token1.balanceOf(alice), balance1);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), first.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), first.commission1);
        ValariRouterV3.PositionView memory afterClaim = router.getPosition(tokenId);
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
            ValariRouterV3.PositionView memory pending = router.getPosition(tokenId);
            uint256 cut0 = (totalFees0 + pending.fees0) / 10 - totalFees0 / 10;
            uint256 cut1 = (totalFees1 + pending.fees1) / 10 - totalFees1 / 10;
            assertLt(pending.fees0, 10);
            assertLt(pending.fees1, 10);
            assertEq(pending.commission0, cut0);
            assertEq(pending.commission1, cut1);
            assertEq(pending.netFees0, pending.fees0 - cut0);
            assertEq(pending.netFees1, pending.fees1 - cut1);
            vm.prank(alice);
            ValariRouterV3.Payout memory paid = router.collectFees(tokenId, block.timestamp);
            _assertPayout(paid, 0, 0, pending.fees0, pending.fees1, cut0, cut1);
            totalFees0 += pending.fees0;
            totalFees1 += pending.fees1;
            assertEq(router.claimableCommission(feeRecipient, address(token0)), totalFees0 / 10);
            assertEq(router.claimableCommission(feeRecipient, address(token1)), totalFees1 / 10);
            ValariRouterV3.PositionView memory afterClaim = router.getPosition(tokenId);
            assertEq(afterClaim.feesCollected0, totalFees0);
            assertEq(afterClaim.feesCollected1, totalFees1);
            assertEq(afterClaim.commissionAccrued0, totalFees0 / 10);
            assertEq(afterClaim.commissionAccrued1, totalFees1 / 10);
        }
        manager.unlock(abi.encode(true, false, uint256(7), uint256(9)));
        ValariRouterV3.PositionView memory beforeExit = router.getPosition(tokenId);
        uint256 finalCut0 = (totalFees0 + beforeExit.fees0) / 10 - totalFees0 / 10;
        uint256 finalCut1 = (totalFees1 + beforeExit.fees1) / 10 - totalFees1 / 10;
        vm.prank(alice);
        ValariRouterV3.Payout memory exited = router.exitPosition(tokenId, 0, 0, block.timestamp);
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
        ValariRouterV3.PositionView memory closed = router.getPosition(tokenId);
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
        ValariRouterV3.PositionView memory beforeAction = router.getPosition(tokenId);
        vm.expectRevert();
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp - 1);
        vm.expectRevert();
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp - 1);
        ValariRouterV3.PositionView memory afterAction = router.getPosition(tokenId);
        assertEq(afterAction.liquidity, liquidity);
        assertEq(afterAction.fees0, beforeAction.fees0);
        assertEq(afterAction.fees1, beforeAction.fees1);
        assertEq(afterAction.feesCollected0, 0);
        assertEq(afterAction.feesCollected1, 0);
    }

    function testExitMinimumPrincipalRevertsAtomicallyEvenWithEnoughFees() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        ValariRouterV3.PositionView memory beforeExit = router.getPosition(tokenId);
        uint256 user0 = token0.balanceOf(alice);
        uint256 user1 = token1.balanceOf(alice);
        vm.expectRevert();
        vm.prank(alice);
        router.exitPosition(tokenId, uint128(beforeExit.amount0 + 1), 0, block.timestamp);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        ValariRouterV3.PositionView memory afterExit = router.getPosition(tokenId);
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
                ValariRouterV3.exitPosition, (tokenId, uint128(0), uint128(0), block.timestamp)
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
            address(router), abi.encodeCall(ValariRouterV3.collectFees, (tokenId, block.timestamp))
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
        ValariRouterV3.Payout memory first = router.collectFees(tokenId, block.timestamp);
        address replacement = makeAddr("replacement treasury");
        router.setFeeRecipient(replacement);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        uint256 user0 = token0.balanceOf(alice);
        uint256 user1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouterV3.Payout memory last = router.exitPosition(tokenId, 0, 0, block.timestamp);
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
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp);
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
        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
        assertEq(position.commissionAccrued0, collected.commission0);
        assertEq(position.commissionAccrued1, collected.commission1);
        assertEq(position.liquidity, liquidity);
        assertEq(position.nftOwner, address(router));
    }

    function testCommissionWithdrawalsRejectInvalidAmountsDestinationsAndOtherCallers() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(2 ether)));
        vm.prank(alice);
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        vm.expectRevert(ValariRouterV3.InsufficientCommission.selector);
        vm.prank(alice);
        router.withdrawCommission(address(token0), alice, collected.commission0);
        vm.expectRevert(ValariRouterV3.InsufficientCommission.selector);
        router.withdrawCommission(address(token0), address(this), collected.commission0);
        vm.startPrank(feeRecipient);
        vm.expectRevert(ValariRouterV3.InvalidCommissionWithdrawal.selector);
        router.withdrawCommission(address(0), feeRecipient, collected.commission0);
        vm.expectRevert(ValariRouterV3.InvalidCommissionWithdrawal.selector);
        router.withdrawCommission(address(token0), address(0), collected.commission0);
        vm.expectRevert(ValariRouterV3.InvalidCommissionWithdrawal.selector);
        router.withdrawCommission(address(token0), address(router), collected.commission0);
        vm.expectRevert(ValariRouterV3.InvalidCommissionWithdrawal.selector);
        router.withdrawCommission(address(token0), feeRecipient, 0);
        vm.expectRevert(ValariRouterV3.InsufficientCommission.selector);
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
        ValariRouterV3.Payout memory first = router.collectFees(tokenId, block.timestamp);
        address replacement = makeAddr("replacement treasury");
        router.setFeeRecipient(replacement);
        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        vm.prank(alice);
        ValariRouterV3.Payout memory last = router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(
            router.totalClaimableCommission(address(token0)), first.commission0 + last.commission0
        );
        assertEq(
            router.totalClaimableCommission(address(token1)), first.commission1 + last.commission1
        );
        vm.expectRevert(ValariRouterV3.InsufficientCommission.selector);
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
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        assertEq(token0.balanceOf(alice) - user0, collected.amount0);
        assertEq(token1.balanceOf(alice) - user1, collected.amount1);
        assertEq(router.getPosition(tokenId).liquidity, liquidity);
        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        ValariRouterV3.PositionView memory beforeExit = router.getPosition(tokenId);
        user0 = token0.balanceOf(alice);
        user1 = token1.balanceOf(alice);
        vm.prank(alice);
        ValariRouterV3.Payout memory exited = router.exitPosition(
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
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp);
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
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        token0.setCallback(
            address(router),
            abi.encodeCall(
                ValariRouterV3.withdrawCommission, (address(token0), feeRecipient, uint256(1))
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
        ValariRouterV3.Payout memory collected = router.collectFees(first, block.timestamp);
        (uint256 second,,,) = _open(bob, 2 * BUDGET, BUDGET, -600, 600);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), collected.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), collected.commission1);
        _assertCommissionBacking(23 ether, 19 ether);
        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        vm.prank(alice);
        ValariRouterV3.Payout memory exitFirst = router.exitPosition(first, 0, 0, block.timestamp);
        vm.prank(bob);
        ValariRouterV3.Payout memory exitSecond = router.exitPosition(second, 0, 0, block.timestamp);
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
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        manager.unlock(abi.encode(true, false, uint256(3 ether), uint256(4 ether)));
        ValariRouterV3.PositionView memory beforeAction = router.getPosition(tokenId);
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
        ValariRouterV3.PositionView memory afterAction = router.getPosition(tokenId);
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
        ValariRouterV3.Payout memory paid,
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
        ValariRouterV3.PositionView memory position = router.getPosition(tokenId);
        assertApproxEqAbs(position.amount0, spent0, 1);
        assertApproxEqAbs(position.amount1, spent1, 1);
        _assertNoAllowances();
    }

    // ------------------------------------------------------------------------------------
    // V3: price bounds on openPosition
    // ------------------------------------------------------------------------------------

    function _boundsAround(uint160 price) internal pure returns (uint160 low, uint160 high) {
        // 0.5% on the sqrt price is about 1% on the price.
        low = uint160(uint256(price) * 995 / 1000);
        high = uint160(uint256(price) * 1005 / 1000);
    }

    function testPriceBoundsStopSandwichThatPassesMinimumLiquidity() public {
        _open(bob, 1_000 ether, 1_000 ether, -600, 1800);
        // A token0-only range above spot, with a loose token1 budget.
        ValariRouterV3.DepositQuote memory honest =
            router.previewDeposit(poolId, 100 ether, 130 ether, 600, 1200);
        assertEq(honest.amount1, 0);
        uint128 minLiquidity = honest.liquidity * 99 / 100;
        (uint160 low, uint160 high) = _boundsAround(honest.sqrtPriceX96);

        // Front-run past the range: the same budgets now buy more liquidity, in token1.
        manager.unlock(abi.encode(false, false, uint256(800 ether), uint256(0)));
        ValariRouterV3.DepositQuote memory moved =
            router.previewDeposit(poolId, 100 ether, 130 ether, 600, 1200);
        assertGt(moved.liquidity, minLiquidity, "minimum liquidity alone would pass");
        assertEq(moved.amount0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.PriceOutOfBounds.selector, moved.sqrtPriceX96, low, high
            )
        );
        vm.prank(alice);
        router.openPosition(
            poolId, 100 ether, 130 ether, 600, 1200, minLiquidity, low, high, block.timestamp
        );
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE);
        assertEq(router.positionCount(), 1);
    }

    function testPriceBoundsAreInclusiveAndRejectOneUnitOutside() public {
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        uint160 price = quote.sqrtPriceX96;
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.PriceOutOfBounds.selector, price, price + 1, price + 2
            )
        );
        router.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            quote.liquidity,
            price + 1,
            price + 2,
            block.timestamp
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.PriceOutOfBounds.selector, price, price - 2, price - 1
            )
        );
        router.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            quote.liquidity,
            price - 2,
            price - 1,
            block.timestamp
        );
        router.openPosition(
            poolId, BUDGET, BUDGET, -600, 600, quote.liquidity, price, price, block.timestamp
        );
        vm.stopPrank();
        assertEq(router.positionCount(), 1);
    }

    function testRejectsZeroAndInvertedPriceBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(ValariRouterV3.InvalidPriceBounds.selector);
        router.openPosition(
            poolId, BUDGET, BUDGET, -600, 600, 1, 0, TickMath.MAX_SQRT_PRICE, block.timestamp
        );
        vm.expectRevert(ValariRouterV3.InvalidPriceBounds.selector);
        router.openPosition(
            poolId, BUDGET, BUDGET, -600, 600, 1, SQRT_ONE + 1, SQRT_ONE, block.timestamp
        );
        vm.stopPrank();
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertEq(router.positionCount(), 0);
    }

    // ------------------------------------------------------------------------------------
    // V3: owner-appended pools
    // ------------------------------------------------------------------------------------

    /// @dev A second initialized pool pairing the fixture's USDG (token0) with a new stock.
    function _newStockPool(address stock) internal returns (PoolKey memory added) {
        (address low, address high) =
            stock < address(token0) ? (stock, address(token0)) : (address(token0), stock);
        added = PoolKey({
            currency0: Currency.wrap(low),
            currency1: Currency.wrap(high),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        manager.initialize(added, SQRT_ONE);
    }

    function testOwnerAppendsPoolAndUsersCompleteLifecycleOnIt() public {
        RouterTestToken stock = new RouterTestToken();
        PoolKey memory added = _newStockPool(address(stock));
        bytes32 addedId = keccak256(abi.encode(added));

        vm.expectEmit(true, true, false, true, address(router));
        emit ValariRouterV3.PoolAdded(
            addedId,
            address(stock),
            Currency.unwrap(added.currency0),
            Currency.unwrap(added.currency1),
            10_000,
            200
        );
        assertEq(router.addPool(added), addedId);

        assertEq(router.poolCount(), 2);
        assertEq(router.stockPoolCount(address(stock)), 1);
        assertEq(router.getStockPoolIds(address(stock), 0, 1)[0], addedId);
        assertEq(router.getPoolIds(1, 1)[0], addedId);
        assertEq(router.getPoolKey(addedId).tickSpacing, 200);
        // The original pool is untouched.
        assertEq(router.getPoolIds(0, 1)[0], poolId);
        assertEq(router.getStockPoolIds(address(token1), 0, 1)[0], poolId);

        stock.mint(alice, BUDGET);
        vm.startPrank(alice);
        stock.approve(address(router), BUDGET);
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(addedId, BUDGET, BUDGET, -2000, 2000);
        (uint256 tokenId,, uint256 spent0, uint256 spent1) = router.openPosition(
            addedId,
            BUDGET,
            BUDGET,
            -2000,
            2000,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        ValariRouterV3.Payout memory payout = router.exitPosition(tokenId, 0, 0, block.timestamp);
        vm.stopPrank();
        assertEq(positionManager.nextTokenId(), tokenId + 1);
        assertApproxEqAbs(payout.amount0, spent0, 1);
        assertApproxEqAbs(payout.amount1, spent1, 1);
        assertEq(payout.commission0 + payout.commission1, 0);
        assertEq(stock.balanceOf(address(router)), 0);
    }

    function testOwnerAppendsSecondFeeTierAndBothTiersRunIndependently() public {
        PoolKey memory tier = key;
        tier.fee = 500;
        tier.tickSpacing = 10;
        // The new tier trades at a different price than the first.
        manager.initialize(tier, TickMath.getSqrtPriceAtTick(100));
        bytes32 tierId = keccak256(abi.encode(tier));

        vm.expectEmit(true, true, false, true, address(router));
        emit ValariRouterV3.PoolAdded(
            tierId, address(token1), address(token0), address(token1), 500, 10
        );
        assertEq(router.addPool(tier), tierId);

        assertEq(router.poolCount(), 2);
        assertEq(router.stockPoolCount(address(token1)), 2);
        bytes32[] memory tiers = router.getStockPoolIds(address(token1), 0, 100);
        assertEq(tiers.length, 2);
        assertEq(tiers[0], poolId);
        assertEq(tiers[1], tierId);
        assertEq(router.getStockPoolIds(address(token1), 1, 1)[0], tierId);
        assertEq(router.getStockPoolIds(address(token1), 2, 1).length, 0);
        assertEq(router.getPoolKey(tierId).fee, 500);
        assertEq(router.getPoolKey(poolId).fee, 3000);

        // One position per tier for the same user; each follows its own pool's price.
        (uint256 firstId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(tierId, BUDGET, BUDGET, -600, 600);
        assertEq(quote.sqrtPriceX96, TickMath.getSqrtPriceAtTick(100));
        vm.prank(alice);
        (uint256 secondId,,,) = router.openPosition(
            tierId,
            BUDGET,
            BUDGET,
            -600,
            600,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        assertEq(router.getPosition(firstId).poolId, poolId);
        assertEq(router.getPosition(secondId).poolId, tierId);
        assertEq(router.getPosition(secondId).poolKey.fee, 500);

        // Fees earned in the first tier belong to the first position only.
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(0)));
        assertGt(router.getPosition(firstId).fees0, 0);
        assertEq(router.getPosition(secondId).fees0, 0);

        vm.startPrank(alice);
        ValariRouterV3.Payout memory second = router.exitPosition(secondId, 0, 0, block.timestamp);
        assertEq(second.fees0 + second.fees1, 0);
        assertEq(second.commission0 + second.commission1, 0);
        ValariRouterV3.Payout memory first = router.exitPosition(firstId, 0, 0, block.timestamp);
        vm.stopPrank();
        assertGt(first.fees0, 0);
        assertEq(first.commission0, first.fees0 / 10);
        // Both tiers share token0, so its commission reserve is one balance.
        assertEq(token0.balanceOf(address(router)), first.commission0);
        assertEq(router.totalClaimableCommission(address(token0)), first.commission0);
        assertEq(token1.balanceOf(address(router)), 0);
    }

    function testOnlyOwnerAppendsPools() public {
        PoolKey memory added = _newStockPool(address(new RouterTestToken()));
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", feeRecipient)
        );
        vm.prank(feeRecipient);
        router.addPool(added);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        router.addPool(added);
        assertEq(router.poolCount(), 1);
    }

    function testAppendedPoolsPassTheSameChecksAsTheConstructor() public {
        // Already listed.
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.DuplicatePool.selector, poolId));
        router.addPool(key);

        RouterTestToken stock = new RouterTestToken();
        PoolKey memory added = _newStockPool(address(stock));

        // Not initialized.
        PoolKey memory candidate = _copy(added);
        candidate.fee = 3000;
        candidate.tickSpacing = 60;
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.InvalidPool.selector, keccak256(abi.encode(candidate))
            )
        );
        router.addPool(candidate);

        // Hooked.
        candidate = _copy(added);
        candidate.hooks = IHooks(address(0x1000));
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.InvalidPool.selector, keccak256(abi.encode(candidate))
            )
        );
        router.addPool(candidate);

        // Reversed currencies.
        candidate = _copy(added);
        (candidate.currency0, candidate.currency1) = (added.currency1, added.currency0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.InvalidPool.selector, keccak256(abi.encode(candidate))
            )
        );
        router.addPool(candidate);

        // No USDG side.
        RouterTestToken other = new RouterTestToken();
        (address low, address high) = address(stock) < address(other)
            ? (address(stock), address(other))
            : (address(other), address(stock));
        candidate = _copy(added);
        candidate.currency0 = Currency.wrap(low);
        candidate.currency1 = Currency.wrap(high);
        manager.initialize(candidate, SQRT_ONE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.InvalidPool.selector, keccak256(abi.encode(candidate))
            )
        );
        router.addPool(candidate);

        assertEq(router.poolCount(), 1);
        assertEq(router.stockPoolCount(address(stock)), 0);
        bytes32 addedId = router.addPool(added);
        assertEq(router.poolCount(), 2);
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.DuplicatePool.selector, addedId));
        router.addPool(added);
        assertEq(router.poolCount(), 2);
        assertEq(router.stockPoolCount(address(stock)), 1);
    }

    /// @dev Memory structs alias on assignment; candidates must not mutate the original.
    function _copy(PoolKey memory source) internal pure returns (PoolKey memory) {
        return
            PoolKey(
                source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks
            );
    }

    function testEmptyRouterIsFilledByAppendingPools() public {
        ValariRouterV3 empty =
            new ValariRouterV3(positionManager, stateView, address(token0), new PoolKey[](0));
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, poolId));
        empty.getPoolKey(poolId);
        assertEq(empty.addPool(key), poolId);
        assertEq(empty.poolCount(), 1);
        assertEq(empty.getStockPoolIds(address(token1), 0, 1)[0], poolId);

        vm.startPrank(alice);
        token0.approve(address(empty), BUDGET);
        token1.approve(address(empty), BUDGET);
        ValariRouterV3.DepositQuote memory quote =
            empty.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        (uint256 tokenId,,,) = empty.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        vm.stopPrank();
        assertEq(positionManager.ownerOf(tokenId), address(empty));
    }

    // ------------------------------------------------------------------------------------
    // V3: a surplus left by the token no longer blocks collection or exit
    // ------------------------------------------------------------------------------------

    function testExitSurvivesTokenThatDebitsRouterLessThanItSends() public {
        StickySenderToken stock = new StickySenderToken();
        PoolKey memory added = _newStockPool(address(stock));
        bytes32 addedId = router.addPool(added);

        stock.mint(alice, BUDGET);
        vm.startPrank(alice);
        stock.approve(address(router), BUDGET);
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(addedId, BUDGET, BUDGET, -2000, 2000);
        (uint256 newId,, uint256 spent0, uint256 spent1) = router.openPosition(
            addedId,
            BUDGET,
            BUDGET,
            -2000,
            2000,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        vm.stopPrank();

        // The token starts leaving one unit behind in the router on every payout.
        stock.setStickySender(address(router));
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 usdgBefore = token0.balanceOf(alice);
        vm.prank(alice);
        ValariRouterV3.Payout memory payout = router.exitPosition(newId, 0, 0, block.timestamp);
        bool stockIs0 = Currency.unwrap(added.currency0) == address(stock);
        (uint256 stockPaid, uint256 usdgPaid) =
            stockIs0 ? (payout.amount0, payout.amount1) : (payout.amount1, payout.amount0);
        (uint256 stockSpent, uint256 usdgSpent) = stockIs0 ? (spent0, spent1) : (spent1, spent0);
        assertEq(stock.balanceOf(alice) - stockBefore, stockPaid - 1, "one unit stayed behind");
        assertEq(token0.balanceOf(alice) - usdgBefore, usdgPaid);
        assertApproxEqAbs(stockPaid, stockSpent, 1);
        assertApproxEqAbs(usdgPaid, usdgSpent, 1);
        assertEq(stock.balanceOf(address(router)), 1, "surplus is dust in the router");
        assertTrue(router.getPosition(newId).closed);
    }

    function testPayoutStillCannotDrawOnEarlierBalances() public {
        // The relaxed check keeps the direction that matters: a token debiting the router
        // MORE than it sends would eat dust or commission reserves, and still reverts.
        StickySenderToken stock = new StickySenderToken();
        bytes32 addedId = router.addPool(_newStockPool(address(stock)));
        stock.mint(alice, BUDGET);
        vm.startPrank(alice);
        stock.approve(address(router), BUDGET);
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(addedId, BUDGET, BUDGET, -2000, 2000);
        (uint256 tokenId,,,) = router.openPosition(
            addedId,
            BUDGET,
            BUDGET,
            -2000,
            2000,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        vm.stopPrank();
        stock.mint(address(router), 5);

        stock.setGreedySender(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouterV3.UnsupportedToken.selector, address(stock))
        );
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(stock.balanceOf(address(router)), 5);
        assertFalse(router.getPosition(tokenId).closed);

        stock.setGreedySender(address(0));
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(stock.balanceOf(address(router)), 5);
    }

    // ------------------------------------------------------------------------------------
    // V3: review fixes — bounded surplus, price re-read before the mint, unlistable stocks
    // ------------------------------------------------------------------------------------

    /// @dev A pool of USDG and a faulty stock, with a position for alice and fees to collect.
    function _faultyStockPosition()
        internal
        returns (StickySenderToken stock, PoolKey memory added, uint256 tokenId)
    {
        stock = new StickySenderToken();
        added = _newStockPool(address(stock));
        bytes32 addedId = router.addPool(added);
        stock.mint(alice, BUDGET);
        vm.startPrank(alice);
        stock.approve(address(router), BUDGET);
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(addedId, BUDGET, BUDGET, -2000, 2000);
        (tokenId,,,) = router.openPosition(
            addedId,
            BUDGET,
            BUDGET,
            -2000,
            2000,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        vm.stopPrank();
        PoolDonor donor = new PoolDonor(manager);
        stock.mint(address(donor), 1 ether);
        token0.mint(address(donor), 1 ether);
        donor.donate(added, 1 ether, 1 ether);
    }

    function testTokenReportingTransfersItDidNotMakeCannotCollectOrCloseAPosition() public {
        (StickySenderToken stock,, uint256 tokenId) = _faultyStockPosition();
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 usdgBefore = token0.balanceOf(alice);

        // The token starts returning success for router payouts without moving anything.
        stock.setMutedSender(address(router));
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouterV3.UnsupportedToken.selector, address(stock))
        );
        router.collectFees(tokenId, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouterV3.UnsupportedToken.selector, address(stock))
        );
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        vm.stopPrank();

        // Nothing was lost: the position is open, in custody, and nothing sits in the router.
        assertFalse(router.getPosition(tokenId).closed);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(stock.balanceOf(alice), stockBefore);
        assertEq(token0.balanceOf(alice), usdgBefore);

        // Once the token behaves, the same position pays out in full.
        stock.setMutedSender(address(0));
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertGt(stock.balanceOf(alice), stockBefore);
        assertGt(token0.balanceOf(alice), usdgBefore);
        assertTrue(router.getPosition(tokenId).closed);
    }

    function testSurplusToleranceStopsAtMaxPayoutDust() public {
        (StickySenderToken stock,, uint256 tokenId) = _faultyStockPosition();
        assertEq(router.MAX_PAYOUT_DUST(), 2);
        stock.setStickySender(address(router));

        stock.setStickyUnits(3);
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouterV3.UnsupportedToken.selector, address(stock))
        );
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);

        stock.setStickyUnits(2);
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        uint256 commission = router.claimableCommission(feeRecipient, address(stock));
        assertGt(commission, 0);
        // The commission is fully backed, plus the two units the token left behind.
        assertEq(stock.balanceOf(address(router)), commission + 2);
    }

    function testCommissionWithdrawalToleratesDustAndRejectsUnmadeTransfers() public {
        (StickySenderToken stock,, uint256 tokenId) = _faultyStockPosition();
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        uint256 credit = router.claimableCommission(feeRecipient, address(stock));
        assertGt(credit, 10);

        stock.setMutedSender(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouterV3.UnsupportedToken.selector, address(stock))
        );
        vm.prank(feeRecipient);
        router.withdrawCommission(address(stock), feeRecipient, 10);
        assertEq(router.claimableCommission(feeRecipient, address(stock)), credit);

        stock.setMutedSender(address(0));
        stock.setStickySender(address(router));
        vm.prank(feeRecipient);
        router.withdrawCommission(address(stock), feeRecipient, 10);
        assertEq(router.claimableCommission(feeRecipient, address(stock)), credit - 10);
        assertEq(stock.balanceOf(feeRecipient), 9);
        // One unit of dust now sits above the remaining liability; the rest stays withdrawable.
        assertEq(stock.balanceOf(address(router)), credit - 10 + 1);
        stock.setStickySender(address(0));
        vm.prank(feeRecipient);
        router.withdrawCommission(address(stock), feeRecipient, credit - 10);
        assertEq(router.totalClaimableCommission(address(stock)), 0);
        assertEq(stock.balanceOf(address(router)), 1);
    }

    function pushPriceUp() external {
        manager.unlock(abi.encode(false, false, uint256(800 ether), uint256(0)));
    }

    function testTokenCallbackCannotMovePriceBetweenBoundsCheckAndMint() public {
        _open(bob, 1_000 ether, 1_000 ether, -600, 1800);
        ValariRouterV3.DepositQuote memory honest =
            router.previewDeposit(poolId, 100 ether, 130 ether, 600, 1200);
        (uint160 low, uint160 high) = _boundsAround(honest.sqrtPriceX96);

        // Learn where the swap leaves the pool, then rewind.
        uint256 snapshot = vm.snapshotState();
        this.pushPriceUp();
        (uint160 moved,,,) = stateView.getSlot0(PoolId.wrap(poolId));
        assertGt(moved, high);
        vm.revertToState(snapshot);

        // token0 is pulled first; its transferFrom swaps the pool past alice's range. The
        // bounds check already passed on the honest price, and her loose token1 budget would
        // cover the mint at the moved price.
        token0.setCallback(address(this), abi.encodeCall(this.pushPriceUp, ()));
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.PriceOutOfBounds.selector,
                moved,
                honest.sqrtPriceX96,
                honest.sqrtPriceX96
            )
        );
        vm.prank(alice);
        router.openPosition(
            poolId,
            100 ether,
            130 ether,
            600,
            1200,
            honest.liquidity * 99 / 100,
            low,
            high,
            block.timestamp
        );
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE);
        assertEq(router.positionCount(), 1);
    }

    function testProtocolContractsAreNeverListableAsStock() public {
        address[4] memory protocol =
            [address(positionManager), address(manager), address(permit2), address(router)];
        for (uint256 i; i < protocol.length; ++i) {
            PoolKey memory candidate = _newStockPool(protocol[i]);
            bytes32 candidateId = keccak256(abi.encode(candidate));
            vm.expectRevert(
                abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, candidateId)
            );
            router.addPool(candidate);
            if (protocol[i] == address(router)) continue;
            // The constructor applies the same rule to the initial catalog.
            PoolKey[] memory pools = new PoolKey[](1);
            pools[0] = candidate;
            vm.expectRevert(
                abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, candidateId)
            );
            new ValariRouterV3(positionManager, stateView, address(token0), pools);
        }
        assertEq(router.poolCount(), 1);
    }

    // ------------------------------------------------------------------------------------
    // V3: checks the differential review found untested (each fails if its check is removed)
    // ------------------------------------------------------------------------------------

    function _openOn(bytes32 id, address user, uint128 b0, uint128 b1, int24 lower, int24 upper)
        internal
        returns (uint256 tokenId)
    {
        ValariRouterV3.DepositQuote memory quote = router.previewDeposit(id, b0, b1, lower, upper);
        vm.prank(user);
        (tokenId,,,) = router.openPosition(
            id,
            b0,
            b1,
            lower,
            upper,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
    }

    /// @dev The price moves from the router's approve() call, after both pulls.
    function testApproveCallbackCannotMovePriceBetweenBoundsCheckAndMint() public {
        ApproveHookToken stock = new ApproveHookToken();
        PoolKey memory added = _newStockPool(address(stock));
        bytes32 addedId = router.addPool(added);
        key = added; // route the suite's swap callback to the new pool
        poolId = addedId;
        stock.mint(address(this), INITIAL_BALANCE);
        stock.mint(alice, INITIAL_BALANCE);
        stock.mint(bob, INITIAL_BALANCE);
        vm.prank(alice);
        stock.approve(address(router), type(uint256).max);
        vm.prank(bob);
        stock.approve(address(router), type(uint256).max);

        _openOn(addedId, bob, 1_000 ether, 1_000 ether, -2000, 6000);
        ValariRouterV3.DepositQuote memory honest =
            router.previewDeposit(addedId, 100 ether, 150 ether, 2000, 4000);
        (uint160 low, uint160 high) = _boundsAround(honest.sqrtPriceX96);

        uint256 snapshot = vm.snapshotState();
        this.pushPriceUp();
        (uint160 moved,,,) = stateView.getSlot0(PoolId.wrap(addedId));
        assertGt(moved, high);
        vm.revertToState(snapshot);

        stock.setHook(address(router), address(this), abi.encodeCall(this.pushPriceUp, ()));
        vm.expectRevert(
            abi.encodeWithSelector(
                ValariRouterV3.PriceOutOfBounds.selector,
                moved,
                honest.sqrtPriceX96,
                honest.sqrtPriceX96
            )
        );
        vm.prank(alice);
        router.openPosition(
            addedId,
            100 ether,
            150 ether,
            2000,
            4000,
            honest.liquidity * 99 / 100,
            low,
            high,
            block.timestamp
        );
    }

    /// @dev A BEFORE_SWAP-only hook address initializes without any hook call.
    function testInitializedHookedPoolIsNotListable() public {
        PoolKey memory candidate = key;
        candidate.fee = 500;
        candidate.tickSpacing = 10;
        candidate.hooks = IHooks(address(uint160(1 << 7)));
        manager.initialize(candidate, SQRT_ONE);
        bytes32 id = keccak256(abi.encode(candidate));
        (uint160 price,,,) = stateView.getSlot0(PoolId.wrap(id));
        assertGt(price, 0, "pool is initialized");
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, id));
        router.addPool(candidate);
    }

    /// @dev v4 initializes pools whose currency has no code.
    function testCodelessCurrencyIsNotListableOnEitherSide() public {
        address[2] memory stocks =
            [address(uint160(address(token0)) - 1), address(uint160(address(token0)) + 1)];
        for (uint256 i; i < 2; ++i) {
            assertEq(stocks[i].code.length, 0);
            PoolKey memory candidate = _newStockPool(stocks[i]);
            bytes32 id = keccak256(abi.encode(candidate));
            (uint160 price,,,) = stateView.getSlot0(PoolId.wrap(id));
            assertGt(price, 0, "pool is initialized");
            vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, id));
            router.addPool(candidate);
        }
    }

    /// @dev The faulty stock is currency1 here; in the suite it is always currency0.
    function testFaultyStockAsCurrency1CannotCloseAPosition() public {
        StickySenderToken stock;
        do {
            stock = new StickySenderToken();
        } while (address(stock) < address(token0));
        PoolKey memory added = _newStockPool(address(stock));
        bytes32 addedId = router.addPool(added);
        assertEq(Currency.unwrap(added.currency1), address(stock));
        stock.mint(alice, BUDGET);
        vm.prank(alice);
        stock.approve(address(router), BUDGET);
        uint256 tokenId = _openOn(addedId, alice, BUDGET, BUDGET, -2000, 2000);
        stock.setMutedSender(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(ValariRouterV3.UnsupportedToken.selector, address(stock))
        );
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertFalse(router.getPosition(tokenId).closed);
    }

    // ------------------------------------------------------------------------------------
    // V3: deposit switch, eject, alternate payout address, rounding on the inbound side
    // ------------------------------------------------------------------------------------

    function _burnDirectly(address holder, uint256 tokenId, PoolKey memory poolKey) internal {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, holder);
        vm.prank(holder);
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)), params
            ),
            block.timestamp
        );
    }

    function testOwnerStopsAndResumesDepositsForOnePool() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        RouterTestToken otherStock = new RouterTestToken();
        bytes32 otherId = router.addPool(_newStockPool(address(otherStock)));
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(1 ether)));

        assertFalse(router.depositsDisabled(poolId));
        vm.expectEmit(true, false, false, true, address(router));
        emit ValariRouterV3.DepositsDisabledSet(poolId, true);
        router.setDepositsDisabled(poolId, true);
        assertTrue(router.depositsDisabled(poolId));
        assertFalse(router.depositsDisabled(otherId));

        // Quotes still work; the deposit itself is refused and moves nothing.
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(poolId, BUDGET, BUDGET, -600, 600);
        uint256 bob0 = token0.balanceOf(bob);
        uint256 bob1 = token1.balanceOf(bob);
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.DepositsDisabled.selector, poolId));
        vm.prank(bob);
        router.openPosition(
            poolId,
            BUDGET,
            BUDGET,
            -600,
            600,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        assertEq(token0.balanceOf(bob), bob0);
        assertEq(token1.balanceOf(bob), bob1);
        assertEq(router.positionCount(), 1);

        // The other pool is unaffected.
        otherStock.mint(bob, BUDGET);
        vm.startPrank(bob);
        otherStock.approve(address(router), BUDGET);
        quote = router.previewDeposit(otherId, BUDGET, BUDGET, -2000, 2000);
        router.openPosition(
            otherId,
            BUDGET,
            BUDGET,
            -2000,
            2000,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        vm.stopPrank();
        assertEq(router.positionCount(), 2);

        // Open positions in the stopped pool still collect and exit.
        vm.startPrank(alice);
        ValariRouterV3.Payout memory collected = router.collectFees(tokenId, block.timestamp);
        assertGt(collected.fees0, 0);
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        vm.stopPrank();
        assertTrue(router.getPosition(tokenId).closed);

        router.setDepositsDisabled(poolId, false);
        _open(bob, BUDGET, BUDGET, -600, 600);
        assertEq(router.positionCount(), 3);
    }

    function testOnlyOwnerSetsPoolSwitchesAndOnlyForListedPools() public {
        bytes32 unknown = bytes32(uint256(42));
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, unknown));
        router.setDepositsDisabled(unknown, true);
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.InvalidPool.selector, unknown));
        router.setEjectEnabled(unknown, true);

        address[2] memory outsiders = [alice, feeRecipient];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.startPrank(outsiders[i]);
            vm.expectRevert(
                abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsiders[i])
            );
            router.setDepositsDisabled(poolId, true);
            vm.expectRevert(
                abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsiders[i])
            );
            router.setEjectEnabled(poolId, true);
            vm.stopPrank();
        }
        assertFalse(router.depositsDisabled(poolId));
        assertFalse(router.ejectEnabled(poolId));
    }

    function testEjectIsOffUntilTheOwnerEnablesItForThatPool() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        RouterTestToken otherStock = new RouterTestToken();
        bytes32 otherId = router.addPool(_newStockPool(address(otherStock)));

        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.EjectDisabled.selector, poolId));
        vm.prank(alice);
        router.ejectPosition(tokenId, alice);

        // Enabling it for another pool changes nothing for this one.
        router.setEjectEnabled(otherId, true);
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.EjectDisabled.selector, poolId));
        vm.prank(alice);
        router.ejectPosition(tokenId, alice);

        vm.expectEmit(true, false, false, true, address(router));
        emit ValariRouterV3.EjectEnabledSet(poolId, true);
        router.setEjectEnabled(poolId, true);
        router.setEjectEnabled(poolId, false);
        vm.expectRevert(abi.encodeWithSelector(ValariRouterV3.EjectDisabled.selector, poolId));
        vm.prank(alice);
        router.ejectPosition(tokenId, alice);
        assertEq(positionManager.ownerOf(tokenId), address(router));
        assertFalse(router.getPosition(tokenId).closed);
    }

    function testEjectFreesAPositionTheRouterCanNoLongerPayOut() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        (uint256 bobId,,,) = _open(bob, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(1 ether)));
        ValariRouterV3.PositionView memory before = router.getPosition(tokenId);
        assertGt(before.fees1, 0);

        // The stock's issuer restricts the router: nothing can be paid into it any more.
        token1.setBlockedRecipient(address(router), true);
        vm.startPrank(alice);
        vm.expectRevert();
        router.collectFees(tokenId, block.timestamp);
        vm.expectRevert();
        router.exitPosition(tokenId, 0, 0, block.timestamp);
        vm.expectRevert();
        router.exitPositionTo(tokenId, makeAddr("elsewhere"), 0, 0, block.timestamp);
        vm.stopPrank();

        router.setEjectEnabled(poolId, true);

        // Only the depositor can eject, and not to nowhere or back into the router.
        vm.expectRevert(ValariRouterV3.NotPositionOwner.selector);
        vm.prank(bob);
        router.ejectPosition(tokenId, bob);
        vm.expectRevert(ValariRouterV3.NotPositionOwner.selector);
        router.ejectPosition(tokenId, address(this));
        vm.startPrank(alice);
        vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
        router.ejectPosition(tokenId, address(0));
        vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
        router.ejectPosition(tokenId, address(router));

        vm.expectEmit(true, true, true, true, address(router));
        emit ValariRouterV3.PositionEjected(alice, tokenId, alice);
        router.ejectPosition(tokenId, alice);

        // The router's part is over; the NFT and its liquidity are alice's.
        vm.expectRevert(ValariRouterV3.PositionClosed.selector);
        router.ejectPosition(tokenId, alice);
        vm.expectRevert(ValariRouterV3.PositionClosed.selector);
        router.collectFees(tokenId, block.timestamp);
        vm.stopPrank();
        assertEq(positionManager.ownerOf(tokenId), alice);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        ValariRouterV3.PositionView memory ejected = router.getPosition(tokenId);
        assertTrue(ejected.closed);
        assertEq(ejected.nftOwner, alice);
        assertEq(ejected.depositor, alice);
        (ValariRouterV3.PositionView[] memory active,) = router.getUserPositions(alice, 0, 10);
        assertEq(active.length, 0);

        // She exits on Uniswap directly and receives principal and every fee, uncharged.
        uint256 alice0 = token0.balanceOf(alice);
        uint256 alice1 = token1.balanceOf(alice);
        _burnDirectly(alice, tokenId, key);
        assertEq(token0.balanceOf(alice) - alice0, before.amount0 + before.fees0);
        assertEq(token1.balanceOf(alice) - alice1, before.amount1 + before.fees1);
        assertEq(router.totalClaimableCommission(address(token0)), 0);
        assertEq(router.totalClaimableCommission(address(token1)), 0);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);

        // Bob's position is untouched and still in custody.
        assertEq(positionManager.ownerOf(bobId), address(router));
        assertFalse(router.getPosition(bobId).closed);
    }

    function testEjectCanDeliverTheNftToAnotherAddress() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        address vault = makeAddr("vault");
        router.setEjectEnabled(poolId, true);
        vm.prank(alice);
        router.ejectPosition(tokenId, vault);
        assertEq(positionManager.ownerOf(tokenId), vault);
        assertEq(router.getPosition(tokenId).nftOwner, vault);
        uint256 vault1 = token1.balanceOf(vault);
        _burnDirectly(vault, tokenId, key);
        assertGt(token1.balanceOf(vault), vault1);
    }

    function testBeneficiaryWhoCannotReceiveATokenIsPaidAtAnotherAddress() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(1 ether)));
        address carol = makeAddr("carol");
        ValariRouterV3.PositionView memory view_ = router.getPosition(tokenId);

        token1.setBlockedRecipient(alice, true);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(RouterTestToken.RecipientBlocked.selector, alice));
        router.collectFees(tokenId, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RouterTestToken.RecipientBlocked.selector, alice));
        router.exitPosition(tokenId, 0, 0, block.timestamp);

        vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
        router.collectFeesTo(tokenId, address(0), block.timestamp);
        vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
        router.collectFeesTo(tokenId, address(router), block.timestamp);
        vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
        router.exitPositionTo(tokenId, address(0), 0, 0, block.timestamp);
        vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
        router.exitPositionTo(tokenId, address(router), 0, 0, block.timestamp);

        uint256 alice0 = token0.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(router));
        emit ValariRouterV3.FeesCollected(
            alice,
            tokenId,
            feeRecipient,
            view_.fees0,
            view_.fees1,
            view_.commission0,
            view_.commission1,
            carol
        );
        ValariRouterV3.Payout memory collected =
            router.collectFeesTo(tokenId, carol, block.timestamp);
        vm.stopPrank();
        assertEq(token0.balanceOf(carol), collected.amount0);
        assertEq(token1.balanceOf(carol), collected.amount1);
        assertEq(collected.amount0, view_.netFees0);
        assertEq(collected.amount1, view_.netFees1);
        assertEq(token0.balanceOf(alice), alice0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), view_.commission1);

        // Nobody else can redirect her payouts.
        vm.startPrank(bob);
        vm.expectRevert(ValariRouterV3.NotPositionOwner.selector);
        router.collectFeesTo(tokenId, bob, block.timestamp);
        vm.expectRevert(ValariRouterV3.NotPositionOwner.selector);
        router.exitPositionTo(tokenId, bob, 0, 0, block.timestamp);
        vm.stopPrank();
        vm.expectRevert(ValariRouterV3.NotPositionOwner.selector);
        router.exitPositionTo(tokenId, address(this), 0, 0, block.timestamp);

        view_ = router.getPosition(tokenId);
        vm.prank(alice);
        ValariRouterV3.Payout memory exited = router.exitPositionTo(
            tokenId, carol, uint128(view_.amount0), uint128(view_.amount1), block.timestamp
        );
        assertEq(exited.principal0, view_.amount0);
        assertEq(exited.principal1, view_.amount1);
        assertEq(token0.balanceOf(carol), collected.amount0 + exited.amount0);
        assertEq(token1.balanceOf(carol), collected.amount1 + exited.amount1);
        assertEq(token0.balanceOf(alice), alice0);
        assertTrue(router.getPosition(tokenId).closed);
        vm.expectRevert();
        positionManager.ownerOf(tokenId);
    }

    function testExitSurvivesTokenThatDeliversLessThanThePoolSent() public {
        StickySenderToken stock = new StickySenderToken();
        PoolKey memory added = _newStockPool(address(stock));
        bytes32 addedId = router.addPool(added);
        stock.mint(alice, 2 * BUDGET);
        vm.startPrank(alice);
        stock.approve(address(router), 2 * BUDGET);
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(addedId, BUDGET, BUDGET, -2000, 2000);
        uint256[2] memory tokenIds;
        for (uint256 i; i < 2; ++i) {
            (tokenIds[i],,,) = router.openPosition(
                addedId,
                BUDGET,
                BUDGET,
                -2000,
                2000,
                quote.liquidity,
                quote.sqrtPriceX96,
                quote.sqrtPriceX96,
                block.timestamp
            );
        }
        vm.stopPrank();
        bool stockIs0 = Currency.unwrap(added.currency0) == address(stock);
        ValariRouterV3.PositionView memory held = router.getPosition(tokenIds[0]);
        uint256 stockPrincipal = stockIs0 ? held.amount0 : held.amount1;
        uint256 usdgPrincipal = stockIs0 ? held.amount1 : held.amount0;

        // The stock now rounds against whoever the PoolManager pays. No fees have accrued, so
        // the router receives less than the exact principal. Beyond the tolerance it reverts.
        stock.setStickySender(address(manager));
        stock.setStickyUnits(3);
        vm.expectRevert(ValariRouterV3.InsufficientProceeds.selector);
        vm.prank(alice);
        router.exitPosition(tokenIds[0], 0, 0, block.timestamp);
        assertFalse(router.getPosition(tokenIds[0]).closed);

        // Within it, the exit goes through and pays out exactly what arrived.
        stock.setStickyUnits(2);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 usdgBefore = token0.balanceOf(alice);
        vm.prank(alice);
        ValariRouterV3.Payout memory payout =
            router.exitPosition(tokenIds[0], 0, 0, block.timestamp);
        (uint256 paidStock, uint256 paidUsdg) =
            stockIs0 ? (payout.amount0, payout.amount1) : (payout.amount1, payout.amount0);
        (uint256 principalStock, uint256 feesStock) =
            stockIs0 ? (payout.principal0, payout.fees0) : (payout.principal1, payout.fees1);
        assertEq(paidStock, stockPrincipal - 2);
        assertEq(principalStock, stockPrincipal - 2, "reported principal is what arrived");
        assertEq(feesStock, 0);
        assertEq(paidUsdg, usdgPrincipal);
        assertEq(stock.balanceOf(alice) - stockBefore, paidStock);
        assertEq(token0.balanceOf(alice) - usdgBefore, paidUsdg);
        assertEq(payout.commission0 + payout.commission1, 0);
        assertEq(stock.balanceOf(address(router)), 0);
        assertTrue(router.getPosition(tokenIds[0]).closed);
        assertFalse(router.getPosition(tokenIds[1]).closed);
    }

    // ------------------------------------------------------------------------------------
    // V3: hardening round — renounce disabled, per-withdrawal solvency, eject collects first
    // ------------------------------------------------------------------------------------

    function testOwnershipCannotBeRenounced() public {
        vm.expectRevert(ValariRouterV3.OwnershipNotRenounceable.selector);
        router.renounceOwnership();
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        router.renounceOwnership();
        assertEq(router.owner(), address(this));
        // Transfers still work; only renouncing is closed.
        router.transferOwnership(alice);
        vm.prank(alice);
        router.acceptOwnership();
        assertEq(router.owner(), alice);
        vm.expectRevert(ValariRouterV3.OwnershipNotRenounceable.selector);
        vm.prank(alice);
        router.renounceOwnership();
    }

    function testCommissionStaysClaimableAfterTokensLeaveTheRouter() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(0), uint256(10 ether)));
        vm.prank(alice);
        router.collectFees(tokenId, block.timestamp);
        uint256 credit = router.claimableCommission(feeRecipient, address(token1));
        assertGt(credit, 100);
        assertEq(token1.balanceOf(address(router)), credit);

        // The issuer removes most of the router's balance out of band.
        uint256 left = credit / 3;
        deal(address(token1), address(router), left);

        // Whatever remains is still withdrawable; only the shortfall is refused.
        vm.startPrank(feeRecipient);
        vm.expectRevert(ValariRouterV3.InsufficientProceeds.selector);
        router.withdrawCommission(address(token1), feeRecipient, left + 1);
        router.withdrawCommission(address(token1), feeRecipient, left);
        vm.stopPrank();
        assertEq(token1.balanceOf(feeRecipient), left);
        assertEq(token1.balanceOf(address(router)), 0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), credit - left);
        assertEq(router.totalClaimableCommission(address(token1)), credit - left);
        // Refilled later, the rest follows.
        deal(address(token1), address(router), credit - left);
        vm.prank(feeRecipient);
        router.withdrawCommission(address(token1), feeRecipient, credit - left);
        assertEq(router.totalClaimableCommission(address(token1)), 0);
    }

    function testEjectCollectsFeesAndChargesCommissionWhenTheRouterCanBePaid() public {
        (uint256 tokenId, uint128 liquidity,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(1 ether)));
        ValariRouterV3.PositionView memory held = router.getPosition(tokenId);
        assertGt(held.fees0, 0);
        address vault = makeAddr("vault");
        router.setEjectEnabled(poolId, true);

        vm.expectRevert(ValariRouterV3.OnlySelf.selector);
        router.collectForEject(tokenId, address(this));
        vm.expectRevert(ValariRouterV3.OnlySelf.selector);
        vm.prank(alice);
        router.collectForEject(tokenId, alice);

        uint256 vault0 = token0.balanceOf(vault);
        vm.expectEmit(true, true, true, true, address(router));
        emit ValariRouterV3.FeesCollected(
            alice,
            tokenId,
            feeRecipient,
            held.fees0,
            held.fees1,
            held.commission0,
            held.commission1,
            vault
        );
        vm.expectEmit(true, true, true, true, address(router));
        emit ValariRouterV3.PositionEjected(alice, tokenId, vault);
        vm.prank(alice);
        router.ejectPosition(tokenId, vault);

        // The net fees went to the destination, the commission is credited, and the NFT
        // leaves with its liquidity intact and nothing left to collect.
        assertEq(token0.balanceOf(vault) - vault0, held.netFees0);
        assertEq(router.claimableCommission(feeRecipient, address(token0)), held.commission0);
        assertEq(router.claimableCommission(feeRecipient, address(token1)), held.commission1);
        assertEq(positionManager.ownerOf(tokenId), vault);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity);
        ValariRouterV3.PositionView memory after_ = router.getPosition(tokenId);
        assertTrue(after_.closed);
        assertEq(after_.feesCollected0, held.fees0);
        assertEq(after_.commissionAccrued0, held.commission0);
        uint256 vaultBeforeBurn0 = token0.balanceOf(vault);
        _burnDirectly(vault, tokenId, key);
        assertEq(token0.balanceOf(vault) - vaultBeforeBurn0, held.amount0, "principal only");
    }

    function testEjectStillWorksWhenTheCollectionStepCannotPay() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        manager.unlock(abi.encode(true, false, uint256(1 ether), uint256(1 ether)));
        ValariRouterV3.PositionView memory held = router.getPosition(tokenId);
        router.setEjectEnabled(poolId, true);
        // The stock blocks the router: collection cannot land, so no commission is charged
        // and the fees travel with the NFT.
        token1.setBlockedRecipient(address(router), true);
        vm.prank(alice);
        router.ejectPosition(tokenId, alice);
        assertEq(positionManager.ownerOf(tokenId), alice);
        assertEq(router.totalClaimableCommission(address(token0)), 0);
        assertEq(router.totalClaimableCommission(address(token1)), 0);
        assertEq(router.getPosition(tokenId).feesCollected0, 0);
        uint256 alice1 = token1.balanceOf(alice);
        _burnDirectly(alice, tokenId, key);
        assertEq(token1.balanceOf(alice) - alice1, held.amount1 + held.fees1);
    }

    function testPayoutRecipientCannotBeAProtocolContract() public {
        (uint256 tokenId,,,) = _open(alice, BUDGET, BUDGET, -600, 600);
        router.setEjectEnabled(poolId, true);
        address[3] memory protocol = [address(positionManager), address(manager), address(permit2)];
        vm.startPrank(alice);
        for (uint256 i; i < protocol.length; ++i) {
            vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
            router.collectFeesTo(tokenId, protocol[i], block.timestamp);
            vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
            router.exitPositionTo(tokenId, protocol[i], 0, 0, block.timestamp);
            vm.expectRevert(ValariRouterV3.InvalidRecipient.selector);
            router.ejectPosition(tokenId, protocol[i]);
        }
        vm.stopPrank();
        assertEq(positionManager.ownerOf(tokenId), address(router));
    }

    function testInboundToleranceAppliesToCurrency1() public {
        StickySenderToken stock;
        do {
            stock = new StickySenderToken();
        } while (address(stock) < address(token0));
        PoolKey memory added = _newStockPool(address(stock));
        assertEq(Currency.unwrap(added.currency1), address(stock));
        bytes32 addedId = router.addPool(added);
        stock.mint(alice, BUDGET);
        vm.startPrank(alice);
        stock.approve(address(router), BUDGET);
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(addedId, BUDGET, BUDGET, -2000, 2000);
        (uint256 tokenId,,,) = router.openPosition(
            addedId,
            BUDGET,
            BUDGET,
            -2000,
            2000,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp
        );
        vm.stopPrank();
        uint256 principal1 = router.getPosition(tokenId).amount1;

        stock.setStickySender(address(manager));
        stock.setStickyUnits(3);
        vm.expectRevert(ValariRouterV3.InsufficientProceeds.selector);
        vm.prank(alice);
        router.exitPosition(tokenId, 0, 0, block.timestamp);

        stock.setStickyUnits(2);
        uint256 before = stock.balanceOf(alice);
        vm.prank(alice);
        ValariRouterV3.Payout memory payout = router.exitPosition(tokenId, 0, 0, block.timestamp);
        assertEq(payout.principal1, principal1 - 2);
        assertEq(payout.fees1, 0);
        assertEq(stock.balanceOf(alice) - before, principal1 - 2);
        assertTrue(router.getPosition(tokenId).closed);
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
