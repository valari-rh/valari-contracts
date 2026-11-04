// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {vm} from "./utils/Hevm.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {Permit2Deployer} from "./harness/Permit2Deployer.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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

import {ValariRouterV3} from "../../src/ValariRouterV3.sol";

/// @notice Base contract with state variables and setup functions.
/// @dev Deployment mirrors `test/ValariRouterV3.t.sol::setUp()` and the constructor of the prior
///      Echidna harness (`audit/2026-10-05-v3/echidna/harness/RouterEchidnaV3.sol`): real v4
///      `PoolManager` / `PositionManager` / `StateView`, canonical Permit2 bytecode etched at its
///      fixed address, plain mintable ERC-20s as USDG and two "stock" tokens, three initialized
///      pools of which one is listed at deployment (the other two are appended by the admin
///      dispatcher during the campaign).
abstract contract Base is StringUtils, Clamp, Deployer, Math, IUnlockCallback {
    using DecimalPrinter for uint256;
    using BalanceDeltaLibrary for BalanceDelta;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 1_000 ether;
    /// @dev Whole tokens (MockERC20 scales by 10**decimals); 1_000_000 ether per actor as in the fixtures.
    uint256 internal constant INITIAL_TOKEN_BALANCE = 1_000_000;

    uint256 internal constant POOLS = 3;
    uint256 internal constant TOKENS = 3; // 0 = USDG, 1 = stock A, 2 = stock B
    uint160 internal constant SQRT_ONE = uint160(1 << 96);
    /// @dev Budgets used for the two seed positions (same shape as the Echidna harness).
    uint128 internal constant SEED_BUDGET_SMALL = 100 ether;
    uint128 internal constant SEED_BUDGET_LARGE = 400 ether;

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    /// @dev `closedBy[id]` values: 0 = open, 1 = exited (NFT burned), 2 = ejected (NFT handed out).
    uint8 internal constant CLOSED_OPEN = 0;
    uint8 internal constant CLOSED_EXITED = 1;
    uint8 internal constant CLOSED_EJECTED = 2;

    /// @dev Last observed per-position accumulators (GL-15 / GL-16). `closedSeen` latches on the
    ///      first observation of `closed == true`; afterwards the four accumulators must freeze.
    struct Acc {
        uint256 f0;
        uint256 f1;
        uint256 c0;
        uint256 c1;
        bool closedSeen;
    }

    /// @dev The nine immutable `DepositRecord` fields captured at open (GL-17). `owner` always
    ///      mirrors `depositor` in the view, so it is not stored twice.
    struct RecordAtOpen {
        bytes32 poolId;
        address depositor;
        uint64 openedAt;
        int24 tickLower;
        int24 tickUpper;
        uint128 initialLiquidity;
        uint128 amount0Deposited;
        uint128 amount1Deposited;
    }

    /// @dev Per-token arrays are indexed by `_tokenIndex(token)`; per-pool arrays by pool index.
    ///      Every write happens after the router call succeeded so a revert unwinds it.
    struct Ghosts {
        // ── lifecycle counts (GL-09, GL-10, GL-27)
        uint256 openPositions; // ++ in _recordPosition, -- after exit / eject
        mapping(address => uint256) openCountOf; // same, keyed by depositor
        mapping(address => uint256[]) idsOf; // every id a depositor opened, in order
        // ── commission ledger (GL-04)
        uint256[TOKENS] commissionAccrued; // += Payout.commission0/1 on collect / exit
        uint256[TOKENS] commissionWithdrawn; // += amount on withdrawCommission
        // ── user-side token ledger (GL-12)
        uint256[TOKENS] userDeposited; // += a0/a1 in _recordPosition
        uint256[TOKENS] userPaidOut; // += Payout.amount0/1 on collect / exit
        uint256[TOKENS] userWithdrawn; // += amount on withdrawCommission (to is an actor)
        uint256[TOKENS] userDonated; // += amount in valariRouterV3_donateERC20
        // ── fee provenance (GL-24)
        uint256[TOKENS] feesRealized; // += Payout.fees0/1 on collect / exit
        uint256[TOKENS] donated; // += a0/a1 in pool_donate (success)
        uint256[TOKENS] swapFeeCap; // += ceil(amountIn*fee/1e6) + 1 for tokenIn in pool_swap
        // ── v4 liquidity (GL-25)
        uint256[POOLS] liveLiquidity; // += liq at open, -= initialLiquidity on exit (eject leaves it)
        // ── monotone counters (GL-08), refreshed inside the property
        uint256 lastPoolCount;
        uint256[TOKENS] lastStockPoolCount;
        uint256 lastPositionCount;
        uint256 lastNextTokenId;
        mapping(address => uint256) lastDepositCount;
        // ── per-position transitions (GL-15, GL-16, GL-17, GL-10)
        mapping(uint256 => Acc) lastAcc;
        mapping(uint256 => RecordAtOpen) recordAtOpen;
        mapping(uint256 => uint8) closedBy; // CLOSED_OPEN / CLOSED_EXITED / CLOSED_EJECTED
        mapping(uint256 => address) ejectedTo;
        // ── catalog / admin mirrors (GL-07, GL-20, GL-21, GL-22)
        uint256[] listOrder; // pool indices in listing order
        bool[POOLS] lastDepositsDisabled;
        bool[POOLS] lastEjectEnabled;
        address expectedFeeRecipient;
        address expectedPendingOwner;
        // ── former-recipient credits (GL-29), refreshed inside the property
        mapping(address => uint256[TOKENS]) lastCredit;
        address lastFeeRecipientSeen;
        // ── coverage / triage counters
        uint256 previewFalseRejects; // SP-12
        uint256 boundaryOpens; // SP-22
        uint256 boundaryExits; // SP-22
        uint256 roundTripCycles; // SP-27
    }

    Ghosts internal ghosts;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    address internal admin;

    modifier asActor() virtual {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier asAdmin() virtual {
        vm.startPrank(admin);
        _;
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    PoolManager public poolManager;
    PositionManager public positionManager;
    StateView public stateView;
    IAllowanceTransfer public permit2;
    ValariRouterV3 public router;

    /// @dev tokens[0] is USDG (the quote token every listed pool must contain).
    MockERC20[TOKENS] internal tokens;
    MockERC20 internal usdg;

    /// @dev Pool 0: USDG/stockA fee 3000 spacing 60 (listed at deployment).
    ///      Pool 1: USDG/stockA fee 500 spacing 10 (initialized, appended via addPool).
    ///      Pool 2: USDG/stockB fee 10_000 spacing 200 (initialized, appended via addPool).
    PoolKey[POOLS] internal poolKeys;
    bytes32[POOLS] internal poolIds;
    bool[POOLS] internal listed;

    // ――――――――――――――――――― Harness bookkeeping ―――――――――――――――――――

    /// @dev Every tokenId minted through the router by this harness (open, exited or ejected).
    uint256[] internal positionIds;
    mapping(uint256 tokenId => address depositor) internal depositorOf;
    mapping(uint256 tokenId => uint256 poolIndex) internal poolIndexOf;
    /// @dev Token units transferred straight to the router (never withdrawable), per token index.
    uint256[TOKENS] internal seededDust;
    /// @dev Addresses that ever were `feeRecipient` (credits stay with their holder).
    address[] internal recipientsEver;
    mapping(address => bool) internal isRecipientEver;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    function setup() internal {
        // Both project fixtures warp first so deadlines / openedAt see a realistic timestamp.
        vm.warp(1_800_000_000);

        poolManager = new PoolManager(address(this));
        permit2 = IAllowanceTransfer(new Permit2Deployer().deployPermit2());
        positionManager = new PositionManager(
            poolManager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        stateView = new StateView(poolManager);

        tokens[0] = new MockERC20(address(this), INITIAL_TOKEN_BALANCE, "USDG", "USDG", 18);
        tokens[1] = new MockERC20(address(this), INITIAL_TOKEN_BALANCE, "Stock A", "STKA", 18);
        tokens[2] = new MockERC20(address(this), INITIAL_TOKEN_BALANCE, "Stock B", "STKB", 18);
        usdg = tokens[0];
        vm.label(address(tokens[0]), "USDG");
        vm.label(address(tokens[1]), "StockA");
        vm.label(address(tokens[2]), "StockB");

        _makePool(0, 1, 3000, 60);
        _makePool(1, 1, 500, 10);
        _makePool(2, 2, 10_000, 200);

        PoolKey[] memory initial = new PoolKey[](1);
        initial[0] = poolKeys[0];
        router = new ValariRouterV3(positionManager, stateView, address(usdg), initial);
        listed[0] = true;
        ghosts.listOrder.push(0);
        vm.label(address(router), "ValariRouterV3");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(positionManager), "PositionManager");
        vm.label(address(stateView), "StateView");
        vm.label(address(permit2), "Permit2");

        setupActors();

        // The harness (deployer) is owner and the initial feeRecipient; move accrual to an actor
        // so withdrawCommission is reachable from the actor-driven handlers.
        _noteRecipient(address(this));
        router.setFeeRecipient(actors[0]);
        _noteRecipient(actors[0]);
        ghosts.expectedFeeRecipient = actors[0];
        ghosts.lastFeeRecipientSeen = actors[0];
        ghosts.expectedPendingOwner = address(0);

        // Pre-existing dust the router can never pay out; proves payouts never draw on old balances.
        seededDust[0] = 137;
        seededDust[1] = 251;
        seededDust[2] = 59;
        for (uint256 t; t < TOKENS; ++t) {
            tokens[t].transfer(address(router), seededDust[t]);
        }

        // Seed liquidity so swaps move price and donations have in-range liquidity to credit.
        _seedPosition(actors[0], 0, SEED_BUDGET_SMALL, SEED_BUDGET_SMALL, -120, 120);
        _seedPosition(actors[1], 0, SEED_BUDGET_LARGE, SEED_BUDGET_LARGE, -1200, 1200);
        require(positionIds.length == 2, "Base: seed positions must open");
    }

    function setupActors() internal {
        admin = address(this);
        vm.label(admin, "Admin");

        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            address _actor = address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            if (ACTOR_LABELS.length > i) {
                vm.label(_actor, ACTOR_LABELS[i]);
            }
            for (uint256 t; t < TOKENS; ++t) {
                tokens[t].deal(_actor, INITIAL_TOKEN_BALANCE * 1e18);
                vm.prank(_actor);
                tokens[t].approve(address(router), type(uint256).max);
            }
        }
        actor = actors[0];
    }

    /// @dev Initialize a hookless USDG/stock pool at price 1:1 (tick 0) with the given fee tier.
    function _makePool(uint256 pool, uint256 stock, uint24 fee, int24 spacing) internal {
        (address low, address high) = address(tokens[0]) < address(tokens[stock])
            ? (address(tokens[0]), address(tokens[stock]))
            : (address(tokens[stock]), address(tokens[0]));
        poolKeys[pool] = PoolKey(Currency.wrap(low), Currency.wrap(high), fee, spacing, IHooks(address(0)));
        poolManager.initialize(poolKeys[pool], SQRT_ONE);
        poolIds[pool] = keccak256(abi.encode(poolKeys[pool]));
    }

    /// @dev Quote-then-open exactly as the project fixture's `_open` helper does, as `user`.
    function _seedPosition(
        address user,
        uint256 pool,
        uint128 budget0,
        uint128 budget1,
        int24 lower,
        int24 upper
    ) internal returns (uint256 tokenId) {
        ValariRouterV3.DepositQuote memory quote =
            router.previewDeposit(poolIds[pool], budget0, budget1, lower, upper);
        vm.prank(user);
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        (tokenId, liquidity, amount0, amount1) = router.openPosition(
            poolIds[pool],
            budget0,
            budget1,
            lower,
            upper,
            quote.liquidity,
            quote.sqrtPriceX96,
            quote.sqrtPriceX96,
            block.timestamp + 1 hours
        );
        _recordPosition(tokenId, user, pool, liquidity, amount0, amount1);
    }

    /// @dev Legacy 3-arg form: reads liquidity and the deposited amounts from the router's own
    ///      record so every open path feeds the ghosts even before a handler is migrated.
    function _recordPosition(uint256 tokenId, address depositor, uint256 pool) internal {
        ValariRouterV3.PositionView memory v = router.getPosition(tokenId);
        _recordPosition(
            tokenId, depositor, pool, v.initialLiquidity, v.amount0Deposited, v.amount1Deposited
        );
    }

    /// @dev Records a position the harness opened and feeds every open-time ghost:
    ///      `openPositions`, `openCountOf`, `idsOf`, `userDeposited`, `liveLiquidity`,
    ///      `recordAtOpen`. `amount0/amount1` are the spent amounts returned by `openPosition`,
    ///      in the pool key's currency0/currency1 order.
    function _recordPosition(
        uint256 tokenId,
        address depositor,
        uint256 pool,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) internal {
        positionIds.push(tokenId);
        depositorOf[tokenId] = depositor;
        poolIndexOf[tokenId] = pool;

        ghosts.openPositions += 1;
        ghosts.openCountOf[depositor] += 1;
        ghosts.idsOf[depositor].push(tokenId);
        ghosts.userDeposited[_tokenIndex(address(_token(pool, false)))] += amount0;
        ghosts.userDeposited[_tokenIndex(address(_token(pool, true)))] += amount1;
        ghosts.liveLiquidity[pool] += liquidity;
        _captureRecordAtOpen(tokenId);
    }

    /// @dev Snapshot of the immutable record fields straight from the router (GL-17).
    function _captureRecordAtOpen(uint256 tokenId) internal {
        ValariRouterV3.PositionView memory v = router.getPosition(tokenId);
        RecordAtOpen storage r = ghosts.recordAtOpen[tokenId];
        r.poolId = v.poolId;
        r.depositor = v.depositor;
        r.openedAt = v.openedAt;
        r.tickLower = v.tickLower;
        r.tickUpper = v.tickUpper;
        r.initialLiquidity = v.initialLiquidity;
        r.amount0Deposited = v.amount0Deposited;
        r.amount1Deposited = v.amount1Deposited;
    }

    /// @dev Marks a harness position as exited (NFT burned): lifecycle counts, `closedBy`,
    ///      `liveLiquidity`. Idempotent so clamped + unclamped layers may both call it.
    function _markExited(uint256 tokenId) internal {
        if (ghosts.closedBy[tokenId] != CLOSED_OPEN) return;
        ghosts.closedBy[tokenId] = CLOSED_EXITED;
        ghosts.openPositions -= 1;
        ghosts.openCountOf[depositorOf[tokenId]] -= 1;
        uint256 liq = ghosts.recordAtOpen[tokenId].initialLiquidity;
        uint256 pool = poolIndexOf[tokenId];
        ghosts.liveLiquidity[pool] = ghosts.liveLiquidity[pool] >= liq ? ghosts.liveLiquidity[pool] - liq : 0;
    }

    /// @dev Marks a harness position as ejected (NFT handed to `to`): lifecycle counts,
    ///      `closedBy`, `ejectedTo`. `liveLiquidity` is left alone (the v4 position lives on).
    function _markEjected(uint256 tokenId, address to) internal {
        if (ghosts.closedBy[tokenId] != CLOSED_OPEN) return;
        ghosts.closedBy[tokenId] = CLOSED_EJECTED;
        ghosts.ejectedTo[tokenId] = to;
        ghosts.openPositions -= 1;
        ghosts.openCountOf[depositorOf[tokenId]] -= 1;
    }

    /// @dev Feeds the payout ghosts from a successful collect / exit on `tokenId`'s pool:
    ///      `commissionAccrued`, `userPaidOut`, `feesRealized` (per token index).
    function _recordPayout(uint256 tokenId, ValariRouterV3.Payout memory p) internal {
        uint256 pool = poolIndexOf[tokenId];
        uint256 t0 = _tokenIndex(address(_token(pool, false)));
        uint256 t1 = _tokenIndex(address(_token(pool, true)));
        ghosts.commissionAccrued[t0] += p.commission0;
        ghosts.commissionAccrued[t1] += p.commission1;
        ghosts.userPaidOut[t0] += p.amount0;
        ghosts.userPaidOut[t1] += p.amount1;
        ghosts.feesRealized[t0] += p.fees0;
        ghosts.feesRealized[t1] += p.fees1;
    }

    /// @dev Feeds the withdraw ghosts from a successful `withdrawCommission(token, to, amount)`.
    function _recordWithdraw(address token, uint256 amount) internal {
        uint256 t = _tokenIndex(token);
        ghosts.commissionWithdrawn[t] += amount;
        ghosts.userWithdrawn[t] += amount;
    }

    /// @dev Upper bound on the LP fee a single exact-input swap can charge on `tokenIn`
    ///      (GL-24): `ceil(amountIn * fee / 1e6) + 1`.
    function _recordSwapFeeCap(uint256 pool, bool zeroForOne, uint256 amountIn) internal {
        uint256 fee = poolKeys[pool].fee;
        // zeroForOne sells currency0, otherwise currency1 is the input token.
        uint256 t = _tokenIndex(address(_token(pool, !zeroForOne)));
        ghosts.swapFeeCap[t] += (amountIn * fee + 1e6 - 1) / 1e6 + 1;
    }

    function _noteRecipient(address recipient) internal {
        if (!isRecipientEver[recipient]) {
            isRecipientEver[recipient] = true;
            recipientsEver.push(recipient);
        }
    }

    // ――――――――――――――――――― Uniswap v4 pool driving ―――――――――――――――――――

    /// @dev Swap on pool `pool` with the harness's own tokens; moves sqrtPrice and accrues LP fees.
    ///      Reverts are legitimate v4 outcomes (e.g. no active liquidity) and are left to the caller.
    function _swap(uint256 pool, bool zeroForOne, uint256 amountIn) internal {
        poolManager.unlock(abi.encode(pool, false, zeroForOne, amountIn, uint256(0)));
    }

    /// @dev Donate fees directly to in-range liquidity of pool `pool`.
    function _donate(uint256 pool, uint256 amount0, uint256 amount1) internal {
        poolManager.unlock(abi.encode(pool, true, false, amount0, amount1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Base: not pool manager");
        (uint256 pool, bool donate, bool zeroForOne, uint256 amount0, uint256 amount1) =
            abi.decode(data, (uint256, bool, bool, uint256, uint256));
        PoolKey memory key = poolKeys[pool];
        BalanceDelta delta = donate
            ? poolManager.donate(key, amount0, amount1, "")
            : poolManager.swap(
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
            poolManager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(poolManager), uint256(-int256(delta)));
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint128(delta));
        }
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    function _token(uint256 pool, bool one) internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(one ? poolKeys[pool].currency1 : poolKeys[pool].currency0));
    }

    function _tokenIndex(address token) internal view returns (uint256) {
        for (uint256 t; t < TOKENS; ++t) {
            if (address(tokens[t]) == token) return t;
        }
        revert("Base: unknown token");
    }

    function _price(uint256 pool) internal view returns (uint160 price) {
        (price,,,) = stateView.getSlot0(PoolId.wrap(poolIds[pool]));
    }

    /// @dev Owner of a v4 position NFT, or address(0) once burned (solmate ERC721 reverts).
    function _nftOwner(uint256 tokenId) internal view returns (address) {
        try IERC721(address(positionManager)).ownerOf(tokenId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    function toPool(uint256 seed) internal pure returns (uint256) {
        return seed % POOLS;
    }

    function toPositionId(uint256 seed) internal view returns (uint256) {
        return positionIds[seed % positionIds.length];
    }

    // Maps an arbitrary address to an actor address
    function toActor(address addy) internal view returns (address) {
        // Idempotent: an address that already is an actor maps to itself, so clamped handlers
        // that pre-map `to` and unclamped handlers that map again agree on the payee.
        for (uint256 i; i < actors.length; i++) {
            if (actors[i] == addy) return addy;
        }
        return actors[uint256(uint160(addy)) % actors.length];
    }

    // Maps an arbitrary address to an actor address that is different from the current actor
    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    // Sums the native token balances of all actors
    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    // Sums the ERC-20 token balances of all actors for a given token
    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }
}
