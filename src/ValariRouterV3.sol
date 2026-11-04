// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// The deployed PositionManager exposes this immutable getter, but the upstream
// IPositionManager interface does not declare it.
interface IPermit2Source {
    function permit2() external view returns (IAllowanceTransfer);
}

/// @title ValariRouterV3
/// @notice Holds v4 LP NFTs for users and accrues 10% of realized LP fees to the treasury.
/// @dev Amounts are raw currency0/currency1 units; ranges are aligned v4 ticks.
/// Each recorded depositor alone can collect or exit their position. The owner
/// manages the commission recipient, can append pools to the catalog, can stop
/// new deposits into a pool and can let a pool's depositors take their LP NFTs
/// out of custody. It has no authority over user positions and cannot remove or
/// alter a listed pool.
contract ValariRouterV3 is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint256 public constant MAX_INITIAL_POOLS = 100;
    uint256 public constant MAX_PAGE_SIZE = 100;
    uint256 public constant COMMISSION_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Largest rounding difference, in raw token units, tolerated on either side of
    /// a payout: what the pool delivers short of the principal, and what the payout leaves
    /// behind in the router.
    uint256 public constant MAX_PAYOUT_DUST = 2;
    /// @notice Gas given to the fee collection ejectPosition attempts first. A token that
    /// burns gas instead of reverting cleanly cannot stop the eject itself.
    uint256 public constant EJECT_COLLECT_GAS = 2_000_000;

    IPositionManager public immutable positionManager;
    IStateView public immutable stateView;
    IPoolManager public immutable poolManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable usdg;
    address public feeRecipient;

    /// @notice Earned commission belonging to a recipient, denominated in raw token units.
    /// Changing feeRecipient affects future accrual only; existing credits keep their owner.
    mapping(address recipient => mapping(address token => uint256 amount)) public
        claimableCommission;
    /// @notice Total outstanding commission liabilities for each token, held by this router.
    mapping(address token => uint256 amount) public totalClaimableCommission;

    struct DepositQuote {
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint160 sqrtPriceX96;
    }

    struct DepositRecord {
        bytes32 poolId;
        address depositor;
        uint64 openedAt;
        int24 tickLower;
        int24 tickUpper;
        uint128 initialLiquidity;
        uint128 amount0Deposited;
        uint128 amount1Deposited;
        bool closed;
        uint16 commissionRemainder0;
        uint16 commissionRemainder1;
        uint256 feesCollected0;
        uint256 feesCollected1;
        uint256 commissionAccrued0;
        uint256 commissionAccrued1;
    }

    struct Payout {
        uint256 principal0;
        uint256 principal1;
        uint256 fees0;
        uint256 fees1;
        uint256 commission0;
        uint256 commission1;
        uint256 amount0;
        uint256 amount1;
    }

    struct PositionView {
        uint256 tokenId;
        bytes32 poolId;
        address depositor;
        address owner;
        address nftOwner;
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 initialLiquidity;
        uint128 amount0Deposited;
        uint128 amount1Deposited;
        uint64 openedAt;
        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
        uint256 fees0;
        uint256 fees1;
        uint256 commission0;
        uint256 commission1;
        uint256 netFees0;
        uint256 netFees1;
        uint256 feesCollected0;
        uint256 feesCollected1;
        uint256 commissionAccrued0;
        uint256 commissionAccrued1;
        bool closed;
        bool exists;
        bool inRange;
    }

    mapping(bytes32 => PoolKey) private _pools;
    bytes32[] private _poolIds;
    mapping(address => bytes32[]) private _stockPoolIds;
    /// @notice Pools that currently accept no new deposit. Collection and exit are unaffected.
    mapping(bytes32 poolId => bool disabled) public depositsDisabled;
    /// @notice Pools whose depositors may take their LP NFT out of custody with ejectPosition.
    mapping(bytes32 poolId => bool enabled) public ejectEnabled;
    mapping(uint256 => DepositRecord) private _deposits;
    uint256[] private _positionIds;
    mapping(address => uint256[]) private _depositorPositionIds;

    error InvalidConfiguration();
    error InvalidPool(bytes32 poolId);
    error DuplicatePool(bytes32 poolId);
    error InvalidRange();
    error InvalidLiquidity();
    error InvalidPriceBounds();
    error PriceOutOfBounds(uint160 sqrtPriceX96, uint160 minimum, uint160 maximum);
    error LiquidityBelowMinimum(uint128 actual, uint128 minimum);
    error DeadlineExpired();
    error UnsupportedToken(address token);
    error UnexpectedPosition();
    error UnknownPosition(uint256 tokenId);
    error InvalidPageSize();
    error InvalidOwner();
    error InvalidFeeRecipient();
    error InvalidRecipient();
    error DepositsDisabled(bytes32 poolId);
    error EjectDisabled(bytes32 poolId);
    error OwnershipNotRenounceable();
    error OnlySelf();
    error NotPositionOwner();
    error PositionClosed();
    error InsufficientProceeds();
    error InvalidCommissionWithdrawal();
    error InsufficientCommission();

    event PositionOpened(
        address indexed depositor,
        uint256 indexed tokenId,
        bytes32 indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event PoolAdded(
        bytes32 indexed poolId,
        address indexed stock,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing
    );
    event DepositsDisabledSet(bytes32 indexed poolId, bool disabled);
    event EjectEnabledSet(bytes32 indexed poolId, bool enabled);
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event CommissionAccrued(address indexed recipient, address indexed token, uint256 amount);
    event CommissionWithdrawn(
        address indexed recipient, address indexed token, address indexed to, uint256 amount
    );
    event FeesCollected(
        address indexed beneficiary,
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 fees0,
        uint256 fees1,
        uint256 commission0,
        uint256 commission1,
        address to
    );
    event PositionExited(
        address indexed beneficiary,
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 principal0,
        uint256 principal1,
        uint256 fees0,
        uint256 fees1,
        uint256 commission0,
        uint256 commission1,
        address to
    );
    /// @notice The depositor took the LP NFT out of custody; Valari no longer manages it.
    event PositionEjected(address indexed beneficiary, uint256 indexed tokenId, address indexed to);

    /// @dev The initial catalog may be empty; the owner appends further pools with addPool.
    /// Deploy with the checked-in 100-pool Robinhood configuration.
    constructor(
        IPositionManager positionManager_,
        IStateView stateView_,
        address usdg_,
        PoolKey[] memory pools_
    ) Ownable(msg.sender) {
        if (
            address(positionManager_).code.length == 0 || address(stateView_).code.length == 0
                || usdg_.code.length == 0 || pools_.length > MAX_INITIAL_POOLS
        ) revert InvalidConfiguration();
        IPoolManager manager = positionManager_.poolManager();
        IAllowanceTransfer allowanceTransfer = IPermit2Source(address(positionManager_)).permit2();
        if (
            address(manager).code.length == 0 || stateView_.poolManager() != manager
                || address(allowanceTransfer).code.length == 0
        ) revert InvalidConfiguration();
        positionManager = positionManager_;
        stateView = stateView_;
        poolManager = manager;
        permit2 = allowanceTransfer;
        usdg = usdg_;
        feeRecipient = msg.sender;
        emit FeeRecipientUpdated(address(0), msg.sender);

        for (uint256 i; i < pools_.length; ++i) {
            _addPool(pools_[i], stateView_, usdg_);
        }
    }

    /// @notice Append an initialized, hookless USDG/stock pool to the catalog.
    /// @dev Append-only: listed pools can never be removed or changed, so positions already
    /// open are unaffected. A stock may be listed under several fee tiers or tick spacings;
    /// each is its own pool with its own ID.
    function addPool(PoolKey calldata key) external onlyOwner nonReentrant returns (bytes32) {
        return _addPool(key, stateView, usdg);
    }

    /// @notice Ownership cannot be renounced: the owner is the only party who can enable the
    /// eject path when an issuer restricts the router, so an ownerless router would have none.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipNotRenounceable();
    }

    /// @notice Stop or resume new deposits into a listed pool.
    /// @dev For a pool that should not take more funds: a mistaken listing, or a token whose
    /// behaviour changed. Open positions keep collecting and exiting as before.
    function setDepositsDisabled(bytes32 poolId, bool disabled) external onlyOwner nonReentrant {
        getPoolKey(poolId);
        depositsDisabled[poolId] = disabled;
        emit DepositsDisabledSet(poolId, disabled);
    }

    /// @notice Allow or disallow ejectPosition for a listed pool.
    /// @dev The way out when the router can no longer pay out a pool's tokens, for example
    /// because an issuer restricted the router's address. It only ever adds a right for the
    /// pool's depositors; the owner gains no access to any position.
    function setEjectEnabled(bytes32 poolId, bool enabled) external onlyOwner nonReentrant {
        getPoolKey(poolId);
        ejectEnabled[poolId] = enabled;
        emit EjectEnabledSet(poolId, enabled);
    }

    /// @notice Mint an LP NFT into Valari custody for the caller and refund unused budgets.
    /// @param poolId A listed pool that accepts deposits.
    /// @param amount0Max Maximum currency0 units the caller will spend.
    /// @param amount1Max Maximum currency1 units the caller will spend.
    /// @param tickLower Inclusive lower v4 tick, aligned to tickSpacing.
    /// @param tickUpper Exclusive upper v4 tick, aligned to tickSpacing.
    /// @param minLiquidity Caller-selected minimum from a prior quote; must be nonzero.
    /// @param sqrtPriceMinX96 Lowest pool sqrt price the caller accepts; must be nonzero.
    /// @param sqrtPriceMaxX96 Highest pool sqrt price the caller accepts.
    /// @param deadline Caller-selected last permissible block timestamp.
    /// @dev minLiquidity alone does not bound the execution price when a budget has slack:
    /// a moved price can mint more liquidity from the other token. The price bounds do, but
    /// only relative to the reference the caller derived them from: a thin pool's own spot
    /// price can already be off-market when it is quoted.
    function openPosition(
        bytes32 poolId,
        uint128 amount0Max,
        uint128 amount1Max,
        int24 tickLower,
        int24 tickUpper,
        uint128 minLiquidity,
        uint160 sqrtPriceMinX96,
        uint160 sqrtPriceMaxX96,
        uint256 deadline
    )
        external
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        if (minLiquidity == 0) revert InvalidLiquidity();
        if (sqrtPriceMinX96 == 0 || sqrtPriceMinX96 > sqrtPriceMaxX96) revert InvalidPriceBounds();
        PoolKey memory key = getPoolKey(poolId);
        if (depositsDisabled[poolId]) revert DepositsDisabled(poolId);
        DepositQuote memory quote =
            previewDeposit(poolId, amount0Max, amount1Max, tickLower, tickUpper);
        if (quote.sqrtPriceX96 < sqrtPriceMinX96 || quote.sqrtPriceX96 > sqrtPriceMaxX96) {
            revert PriceOutOfBounds(quote.sqrtPriceX96, sqrtPriceMinX96, sqrtPriceMaxX96);
        }
        liquidity = quote.liquidity;
        if (liquidity < minLiquidity) revert LiquidityBelowMinimum(liquidity, minLiquidity);

        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        uint256 before0 = _pull(token0, amount0Max);
        uint256 before1 = _pull(token1, amount1Max);
        _approve(token0, amount0Max);
        _approve(token1, amount1Max);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            amount0Max,
            amount1Max,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        // The transfers and approvals above are the only foreign calls since the quote. If one
        // of them moved the pool, the bounds were checked against a price the mint would not
        // execute at; nothing foreign runs between this read and the mint.
        (uint160 mintPrice,,,) = stateView.getSlot0(PoolId.wrap(poolId));
        if (mintPrice != quote.sqrtPriceX96) {
            revert PriceOutOfBounds(mintPrice, quote.sqrtPriceX96, quote.sqrtPriceX96);
        }
        // Sample after token callbacks/approvals, immediately before the mint.
        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params
            ),
            deadline
        );
        if (
            IERC721(address(positionManager)).ownerOf(tokenId) != address(this)
                || positionManager.getPositionLiquidity(tokenId) != liquidity
                || positionManager.nextTokenId() != tokenId + 1
        ) revert UnexpectedPosition();

        _approve(token0, 0);
        _approve(token1, 0);
        amount0 = _refund(token0, before0, amount0Max);
        amount1 = _refund(token1, before1, amount1Max);

        DepositRecord storage record = _deposits[tokenId];
        record.poolId = poolId;
        record.depositor = msg.sender;
        record.openedAt = block.timestamp.toUint64();
        record.tickLower = tickLower;
        record.tickUpper = tickUpper;
        record.initialLiquidity = liquidity;
        record.amount0Deposited = amount0.toUint128();
        record.amount1Deposited = amount1.toUint128();
        _positionIds.push(tokenId);
        _depositorPositionIds[msg.sender].push(tokenId);
        emit PositionOpened(
            msg.sender, tokenId, poolId, tickLower, tickUpper, liquidity, amount0, amount1
        );
    }

    /// @notice Update the recipient of future commissions; existing credits keep their owner.
    function setFeeRecipient(address newRecipient) external onlyOwner nonReentrant {
        if (newRecipient == address(0) || newRecipient == address(this)) {
            revert InvalidFeeRecipient();
        }
        address previous = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(previous, newRecipient);
    }

    /// @notice Withdraw the caller's accrued commission, independently of user LP operations.
    /// @dev A recipient may use a different destination if a token restricts its own address.
    /// Owner privileges do not grant access to another recipient's existing credits.
    function withdrawCommission(address token, address to, uint256 amount) external nonReentrant {
        if (token == address(0) || to == address(0) || to == address(this) || amount == 0) {
            revert InvalidCommissionWithdrawal();
        }
        uint256 credit = claimableCommission[msg.sender][token];
        if (amount > credit) revert InsufficientCommission();
        IERC20 currency = IERC20(token);
        uint256 beforeBalance = currency.balanceOf(address(this));
        // Solvency is checked per withdrawal, not against the aggregate liability: should an
        // issuer ever remove tokens from the router, what remains stays claimable instead of
        // every recipient's credit in that token freezing at once.
        if (beforeBalance < amount) revert InsufficientProceeds();

        // Effects before interactions; a failed transfer restores both liabilities.
        claimableCommission[msg.sender][token] = credit - amount;
        totalClaimableCommission[token] -= amount;
        currency.safeTransfer(to, amount);
        _checkRetained(currency, beforeBalance - amount);
        emit CommissionWithdrawn(msg.sender, token, to, amount);
    }

    /// @notice Pay the user's net LP fees and accrue Valari's 10% commission for later withdrawal.
    /// @dev Liquidity stays invested. Only the recorded beneficiary can call this function.
    function collectFees(uint256 tokenId, uint256 deadline)
        external
        nonReentrant
        returns (Payout memory)
    {
        return _collectFees(tokenId, msg.sender, deadline);
    }

    /// @notice collectFees, paid to an address the beneficiary chooses.
    /// @dev For a beneficiary who cannot receive one of the tokens at their own address.
    function collectFeesTo(uint256 tokenId, address to, uint256 deadline)
        external
        nonReentrant
        returns (Payout memory)
    {
        return _collectFees(tokenId, to, deadline);
    }

    /// @notice Fully exit and burn the NFT, returning all principal plus fees less 10% of fees.
    /// @param amount0Min Minimum currency0 PRINCIPAL the pool must release, excluding fees.
    /// @param amount1Min Minimum currency1 PRINCIPAL the pool must release, excluding fees.
    /// @dev What reaches the recipient can be up to MAX_PAYOUT_DUST below each minimum, on each
    /// of the two transfer hops, for a token that rounds.
    function exitPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, uint256 deadline)
        external
        nonReentrant
        returns (Payout memory)
    {
        return _exitPosition(tokenId, msg.sender, amount0Min, amount1Min, deadline);
    }

    /// @notice exitPosition, paid to an address the beneficiary chooses.
    /// @dev For a beneficiary who cannot receive one of the tokens at their own address.
    function exitPositionTo(
        uint256 tokenId,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external nonReentrant returns (Payout memory) {
        return _exitPosition(tokenId, to, amount0Min, amount1Min, deadline);
    }

    /// @notice Take the LP NFT out of Valari custody, where the owner has enabled it for the pool.
    /// @dev First attempts an ordinary fee collection, so the commission on fees realized so
    /// far is charged and the net fees go to `to`. If that fails, as it does when the router
    /// can no longer receive one of the pool's tokens, the fees stay with the position and the
    /// eject proceeds anyway: moving the NFT needs no token transfer. Afterwards the position
    /// is closed in this router's records and is the holder's to manage on Uniswap; Valari
    /// charges nothing on it from then on.
    function ejectPosition(uint256 tokenId, address to) external nonReentrant {
        DepositRecord storage record = _ownedPosition(tokenId);
        if (!ejectEnabled[record.poolId]) revert EjectDisabled(record.poolId);
        _checkRecipient(to);
        try this.collectForEject{gas: EJECT_COLLECT_GAS}(tokenId, to) {} catch {}
        record.closed = true;
        IERC721(address(positionManager)).transferFrom(address(this), to, tokenId);
        if (_ownerOf(tokenId) != to) revert UnexpectedPosition();
        emit PositionEjected(record.depositor, tokenId, to);
    }

    /// @notice The collection step of ejectPosition. Callable only by the router itself, so
    /// that a failure can be caught; the caller's authority was checked by ejectPosition.
    function collectForEject(uint256 tokenId, address to) external returns (Payout memory) {
        if (msg.sender != address(this)) revert OnlySelf();
        return _collect(_deposits[tokenId], tokenId, to);
    }

    function _collectFees(uint256 tokenId, address to, uint256 deadline)
        private
        returns (Payout memory)
    {
        DepositRecord storage record = _ownedPosition(tokenId);
        if (block.timestamp > deadline) revert DeadlineExpired();
        _checkRecipient(to);
        return _collect(record, tokenId, to);
    }

    function _collect(DepositRecord storage record, uint256 tokenId, address to)
        private
        returns (Payout memory payout)
    {
        PoolKey memory key = _pools[record.poolId];
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)),
                params
            ),
            block.timestamp // the caller's deadline was checked on entry
        );
        if (
            positionManager.getPositionLiquidity(tokenId) != liquidity
                || _ownerOf(tokenId) != address(this)
        ) {
            revert UnexpectedPosition();
        }
        _distribute(record, payout, to, token0, token1, before0, before1);
        emit FeesCollected(
            record.depositor,
            tokenId,
            feeRecipient,
            payout.fees0,
            payout.fees1,
            payout.commission0,
            payout.commission1,
            to
        );
    }

    function _exitPosition(
        uint256 tokenId,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) private returns (Payout memory payout) {
        DepositRecord storage record = _ownedPosition(tokenId);
        if (block.timestamp > deadline) revert DeadlineExpired();
        _checkRecipient(to);
        PoolKey memory key = _pools[record.poolId];
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        (uint160 price,,,) = stateView.getSlot0(PoolId.wrap(record.poolId));
        (payout.principal0, payout.principal1) = _amounts(
            price,
            TickMath.getSqrtPriceAtTick(record.tickLower),
            TickMath.getSqrtPriceAtTick(record.tickUpper),
            liquidity,
            false
        );
        if (payout.principal0 < amount0Min || payout.principal1 < amount1Min) {
            revert InsufficientProceeds();
        }
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        // No hooks/subscribers or token transfers run before this position's liquidity is
        // removed. The snapshot above therefore matches v4's exact rounded-down principal.
        record.closed = true;
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)), params
            ),
            deadline
        );
        if (_ownerOf(tokenId) != address(0)) revert UnexpectedPosition();
        _distribute(record, payout, to, token0, token1, before0, before1);
        emit PositionExited(
            record.depositor,
            tokenId,
            feeRecipient,
            payout.principal0,
            payout.principal1,
            payout.fees0,
            payout.fees1,
            payout.commission0,
            payout.commission1,
            to
        );
    }

    /// @notice Live quote; apply the user's slippage tolerance to liquidity for minLiquidity.
    /// sqrtPriceX96 is this pool's spot price, which the price bounds should be compared
    /// with an independent reference before being centred on it.
    /// @dev Required funding amounts round up, just as minting does in Uniswap.
    function previewDeposit(
        bytes32 poolId,
        uint128 amount0Max,
        uint128 amount1Max,
        int24 tickLower,
        int24 tickUpper
    ) public view returns (DepositQuote memory quote) {
        PoolKey memory key = getPoolKey(poolId);
        if (
            tickLower >= tickUpper || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK
                || tickLower % key.tickSpacing != 0 || tickUpper % key.tickSpacing != 0
        ) revert InvalidRange();
        (quote.sqrtPriceX96,,,) = stateView.getSlot0(PoolId.wrap(poolId));
        uint160 lower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(tickUpper);
        quote.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            quote.sqrtPriceX96, lower, upper, amount0Max, amount1Max
        );
        if (quote.liquidity == 0 || quote.liquidity > uint128(type(int128).max)) {
            revert InvalidLiquidity();
        }
        (quote.amount0, quote.amount1) =
            _amounts(quote.sqrtPriceX96, lower, upper, quote.liquidity, true);
        if (quote.amount0 > amount0Max || quote.amount1 > amount1Max) revert InvalidLiquidity();
    }

    function getPoolKey(bytes32 poolId) public view returns (PoolKey memory key) {
        key = _pools[poolId];
        if (key.tickSpacing == 0) revert InvalidPool(poolId);
    }

    function poolCount() external view returns (uint256) {
        return _poolIds.length;
    }

    function positionCount() external view returns (uint256) {
        return _positionIds.length;
    }

    /// @notice Historical number opened by this user, including closed positions.
    function depositCount(address depositor) external view returns (uint256) {
        return _depositorPositionIds[depositor].length;
    }

    /// @notice Number of pools listed for a stock: one per fee tier or tick spacing.
    function stockPoolCount(address stock) external view returns (uint256) {
        return _stockPoolIds[stock].length;
    }

    function getPoolIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return _page(_poolIds, offset, limit);
    }

    /// @notice Pools listed for a stock, in the order they were added.
    function getStockPoolIds(address stock, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        return _page(_stockPoolIds[stock], offset, limit);
    }

    /// @notice Historical IDs opened by a user; consult getPosition for their closed status.
    function getDepositorPositionIds(address depositor, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids)
    {
        uint256[] storage all = _depositorPositionIds[depositor];
        uint256 end = _pageEnd(offset, limit, all.length);
        if (offset >= end) return new uint256[](0);
        ids = new uint256[](end - offset);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = all[offset + i];
        }
    }

    /// @notice User ownership, NFT custody, live balances, fee commission and collection history.
    /// @dev owner is the beneficiary; nftOwner is the ERC721 custodian. Principal excludes fees.
    /// A position that was ejected reads as closed with nftOwner set to whoever holds the NFT.
    function getPosition(uint256 tokenId) public view returns (PositionView memory) {
        if (_deposits[tokenId].depositor == address(0)) revert UnknownPosition(tokenId);
        return _positionView(tokenId, _ownerOf(tokenId));
    }

    /// @notice Active positions belonging to this beneficiary, excluding closed positions.
    /// @dev Cursor indexes this USER's historical IDs. Each call scans at most limit IDs; pages
    /// can be empty with more remaining. Continue until nextCursor == depositCount(user).
    function getUserPositions(address user, uint256 cursor, uint256 limit)
        external
        view
        returns (PositionView[] memory positions, uint256 nextCursor)
    {
        if (user == address(0)) revert InvalidOwner();
        uint256[] storage ids = _depositorPositionIds[user];
        nextCursor = _pageEnd(cursor, limit, ids.length);
        if (cursor >= nextCursor) return (new PositionView[](0), nextCursor);
        uint256[] memory matches = new uint256[](nextCursor - cursor);
        uint256 count;
        for (uint256 i = cursor; i < nextCursor; ++i) {
            uint256 id = ids[i];
            if (!_deposits[id].closed) matches[count++] = id;
        }
        positions = new PositionView[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = _positionView(matches[i], _ownerOf(matches[i]));
        }
    }

    function _positionView(uint256 tokenId, address nftOwner)
        private
        view
        returns (PositionView memory p)
    {
        DepositRecord storage record = _deposits[tokenId];
        p.tokenId = tokenId;
        p.poolId = record.poolId;
        p.depositor = record.depositor;
        p.owner = record.depositor;
        p.nftOwner = nftOwner;
        p.poolKey = _pools[record.poolId];
        p.tickLower = record.tickLower;
        p.tickUpper = record.tickUpper;
        p.initialLiquidity = record.initialLiquidity;
        p.amount0Deposited = record.amount0Deposited;
        p.amount1Deposited = record.amount1Deposited;
        p.openedAt = record.openedAt;
        p.closed = record.closed;
        p.feesCollected0 = record.feesCollected0;
        p.feesCollected1 = record.feesCollected1;
        p.commissionAccrued0 = record.commissionAccrued0;
        p.commissionAccrued1 = record.commissionAccrued1;
        p.exists = nftOwner != address(0);
        if (!p.exists || p.closed) return p;

        PoolId id = PoolId.wrap(p.poolId);
        uint256 last0;
        uint256 last1;
        (p.liquidity, last0, last1) = stateView.getPositionInfo(
            id, address(positionManager), p.tickLower, p.tickUpper, bytes32(tokenId)
        );
        int24 tick;
        (p.sqrtPriceX96, tick,,) = stateView.getSlot0(id);
        // An empty position may have uninitialized boundary ticks after removal.
        if (p.liquidity == 0) return p;
        p.inRange = tick >= p.tickLower && tick < p.tickUpper;
        (p.amount0, p.amount1) = _amounts(
            p.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(p.tickLower),
            TickMath.getSqrtPriceAtTick(p.tickUpper),
            p.liquidity,
            false
        );
        (uint256 growth0, uint256 growth1) =
            stateView.getFeeGrowthInside(id, p.tickLower, p.tickUpper);
        // Fee growth intentionally wraps modulo 2^256 in v4.
        unchecked {
            growth0 -= last0;
            growth1 -= last1;
        }
        p.fees0 = FullMath.mulDiv(growth0, p.liquidity, 1 << 128);
        p.fees1 = FullMath.mulDiv(growth1, p.liquidity, 1 << 128);
        (p.commission0,) = _commission(p.fees0, record.commissionRemainder0);
        (p.commission1,) = _commission(p.fees1, record.commissionRemainder1);
        p.netFees0 = p.fees0 - p.commission0;
        p.netFees1 = p.fees1 - p.commission1;
    }

    function _ownedPosition(uint256 tokenId) private view returns (DepositRecord storage record) {
        record = _deposits[tokenId];
        if (record.depositor == address(0)) revert UnknownPosition(tokenId);
        if (record.depositor != msg.sender) revert NotPositionOwner();
        if (record.closed) revert PositionClosed();
        if (_ownerOf(tokenId) != address(this)) revert UnexpectedPosition();
    }

    /// @dev Compute commission on newly realized fees with a per-position, per-currency carry.
    /// Repeated small claims charge floor(total realized fees / 10), not floor(each claim / 10).
    function _commission(uint256 fees, uint16 previousRemainder)
        private
        pure
        returns (uint256 commission, uint16 remainder)
    {
        uint256 fractional = mulmod(fees, COMMISSION_BPS, BPS_DENOMINATOR) + previousRemainder;
        commission =
            FullMath.mulDiv(fees, COMMISSION_BPS, BPS_DENOMINATOR) + fractional / BPS_DENOMINATOR;
        remainder = (fractional % BPS_DENOMINATOR).toUint16();
    }

    /// @dev Actual receipts minus exact exit principal are the newly realized LP fees. The
    /// router has no other measure of fees, so a token that withholds part of them is not
    /// detected; the principal is protected by _split. Update accounting before transfers,
    /// and leave preexisting token balances untouched.
    function _distribute(
        DepositRecord storage record,
        Payout memory payout,
        address to,
        IERC20 token0,
        IERC20 token1,
        uint256 before0,
        uint256 before1
    ) private {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        if (balance0 < before0 || balance1 < before1) revert InsufficientProceeds();
        uint256 received0 = balance0 - before0;
        uint256 received1 = balance1 - before1;
        (payout.principal0, payout.fees0) = _split(received0, payout.principal0);
        (payout.principal1, payout.fees1) = _split(received1, payout.principal1);
        (payout.commission0, record.commissionRemainder0) =
            _commission(payout.fees0, record.commissionRemainder0);
        (payout.commission1, record.commissionRemainder1) =
            _commission(payout.fees1, record.commissionRemainder1);
        payout.amount0 = received0 - payout.commission0;
        payout.amount1 = received1 - payout.commission1;
        record.feesCollected0 += payout.fees0;
        record.feesCollected1 += payout.fees1;
        record.commissionAccrued0 += payout.commission0;
        record.commissionAccrued1 += payout.commission1;

        address recipient = feeRecipient;
        _accrueCommission(recipient, address(token0), payout.commission0);
        _accrueCommission(recipient, address(token1), payout.commission1);
        if (payout.amount0 != 0) token0.safeTransfer(to, payout.amount0);
        if (payout.amount1 != 0) token1.safeTransfer(to, payout.amount1);
        _checkRetained(token0, before0 + payout.commission0);
        _checkRetained(token1, before1 + payout.commission1);
    }

    /// @dev Split what the pool delivered into principal and newly realized fees. A token that
    /// rounds against the receiver can deliver a few units less than the exact principal;
    /// that is paid out as it arrived instead of blocking the exit. A larger shortfall reverts.
    function _split(uint256 received, uint256 expectedPrincipal)
        private
        pure
        returns (uint256 principal, uint256 fees)
    {
        if (received >= expectedPrincipal) {
            return (expectedPrincipal, received - expectedPrincipal);
        }
        if (expectedPrincipal - received > MAX_PAYOUT_DUST) revert InsufficientProceeds();
        return (received, 0);
    }

    /// @dev A payout destination chosen by the beneficiary. The router itself is refused: its
    /// balance is how payouts are measured. The protocol contracts are refused as well, as
    /// they are everywhere else an address is taken; tokens or an NFT sent to them are lost.
    function _checkRecipient(address to) private view {
        if (
            to == address(0) || to == address(this) || to == address(positionManager)
                || to == address(poolManager) || to == address(permit2)
        ) revert InvalidRecipient();
    }

    /// @dev After paying out, the router must hold what it is meant to keep. Less means the
    /// payout drew on earlier balances. A few units more is rounding by the token and stays
    /// as dust rather than blocking the payout. Anything larger means the token reported a
    /// transfer it did not make, and the operation must revert while it can still be retried.
    function _checkRetained(IERC20 token, uint256 expected) private view {
        uint256 held = token.balanceOf(address(this));
        if (held < expected || held - expected > MAX_PAYOUT_DUST) {
            revert UnsupportedToken(address(token));
        }
    }

    function _addPool(PoolKey memory key, IStateView stateView_, address usdg_)
        private
        returns (bytes32 id)
    {
        id = PoolId.unwrap(key.toId());
        if (_pools[id].tickSpacing != 0) revert DuplicatePool(id);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (
            token0 >= token1 || token0.code.length == 0 || token1.code.length == 0
                || (token0 != usdg_ && token1 != usdg_) || address(key.hooks) != address(0)
                || key.tickSpacing < TickMath.MIN_TICK_SPACING
                || key.tickSpacing > TickMath.MAX_TICK_SPACING
        ) revert InvalidPool(id);
        address stock = token0 == usdg_ ? token1 : token0;
        // The router makes ERC20 calls on the stock. Some of those selectors mean something
        // else on the contracts it holds positions and allowances with, so none is listable.
        if (
            stock == address(positionManager) || stock == address(poolManager)
                || stock == address(permit2) || stock == address(this)
        ) revert InvalidPool(id);
        (uint160 sqrtPriceX96,,,) = stateView_.getSlot0(PoolId.wrap(id));
        if (sqrtPriceX96 == 0) revert InvalidPool(id);
        _pools[id] = key;
        _poolIds.push(id);
        _stockPoolIds[stock].push(id);
        emit PoolAdded(id, stock, token0, token1, key.fee, key.tickSpacing);
    }

    function _accrueCommission(address recipient, address token, uint256 amount) private {
        if (amount == 0) return;
        claimableCommission[recipient][token] += amount;
        totalClaimableCommission[token] += amount;
        emit CommissionAccrued(recipient, token, amount);
    }

    function _ownerOf(uint256 tokenId) private view returns (address) {
        try IERC721(address(positionManager)).ownerOf(tokenId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    function _page(bytes32[] storage all, uint256 offset, uint256 limit)
        private
        view
        returns (bytes32[] memory ids)
    {
        uint256 end = _pageEnd(offset, limit, all.length);
        if (offset >= end) return new bytes32[](0);
        ids = new bytes32[](end - offset);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = all[offset + i];
        }
    }

    function _pageEnd(uint256 offset, uint256 limit, uint256 length)
        private
        pure
        returns (uint256)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert InvalidPageSize();
        if (offset >= length) return length;
        return offset + (limit < length - offset ? limit : length - offset);
    }

    function _pull(IERC20 token, uint128 budget) private returns (uint256 beforeBalance) {
        beforeBalance = token.balanceOf(address(this));
        if (budget != 0) token.safeTransferFrom(msg.sender, address(this), budget);
        if (token.balanceOf(address(this)) != beforeBalance + budget) {
            revert UnsupportedToken(address(token));
        }
    }

    function _approve(IERC20 token, uint128 amount) private {
        token.forceApprove(address(permit2), amount);
        // Permit2 treats a zero expiration as block.timestamp. No authority is
        // retained after this transaction; zero amounts revoke the remainder.
        permit2.approve(address(token), address(positionManager), amount, 0);
    }

    function _refund(IERC20 token, uint256 beforeBalance, uint128 budget)
        private
        returns (uint256 spent)
    {
        uint256 remaining = token.balanceOf(address(this));
        if (remaining < beforeBalance || remaining - beforeBalance > budget) {
            revert UnsupportedToken(address(token));
        }
        uint256 refund = remaining - beforeBalance;
        spent = budget - refund;
        if (refund != 0) token.safeTransfer(msg.sender, refund);
        if (token.balanceOf(address(this)) != beforeBalance) {
            revert UnsupportedToken(address(token));
        }
    }

    function _amounts(uint160 price, uint160 lower, uint160 upper, uint128 liquidity, bool roundUp)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (price <= lower) {
            return (SqrtPriceMath.getAmount0Delta(lower, upper, liquidity, roundUp), 0);
        }
        if (price >= upper) {
            return (0, SqrtPriceMath.getAmount1Delta(lower, upper, liquidity, roundUp));
        }
        return (
            SqrtPriceMath.getAmount0Delta(price, upper, liquidity, roundUp),
            SqrtPriceMath.getAmount1Delta(lower, price, liquidity, roundUp)
        );
    }
}
