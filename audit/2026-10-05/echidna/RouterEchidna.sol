// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
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
import {ValariRouter} from "../../../src/ValariRouter.sol";

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
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
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

contract RouterEchidna is DeployPermit2, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    PoolManager internal manager;
    PositionManager internal positions;
    StateView internal state;
    IAllowanceTransfer internal permit;
    ValariRouter internal router;
    AuditToken internal token0;
    AuditToken internal token1;
    AuditActor[2] internal users;
    AuditActor[2] internal treasuries;
    PoolKey internal key;
    bytes32 internal poolId;
    uint256[] internal ids;
    mapping(uint256 => uint256) internal actorOf;
    uint256 internal dust0 = 137;
    uint256 internal dust1 = 251;
    bool internal payoutsCorrect = true;
    bool internal accessCorrect = true;
    bool internal opensCorrect = true;

    constructor() {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        permit = IAllowanceTransfer(deployPermit2());
        positions = new PositionManager(
            manager, permit, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        state = new StateView(manager);
        AuditToken first = new AuditToken();
        AuditToken second = new AuditToken();
        (token0, token1) = address(first) < address(second) ? (first, second) : (second, first);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        poolId = keccak256(abi.encode(key));
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        router = new ValariRouter(positions, state, address(token0), pools);
        for (uint256 i; i < 2; ++i) {
            users[i] = new AuditActor();
            treasuries[i] = new AuditActor();
            token0.mint(address(users[i]), 1_000_000 ether);
            token1.mint(address(users[i]), 1_000_000 ether);
            users[i].invoke(address(token0), abi.encodeCall(token0.approve, (address(router), type(uint256).max)));
            users[i].invoke(address(token1), abi.encodeCall(token1.approve, (address(router), type(uint256).max)));
        }
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.mint(address(router), dust0);
        token1.mint(address(router), dust1);
        router.setFeeRecipient(address(treasuries[0]));
        _open(0, 100 ether, 100 ether, -120, 120);
        _open(1, 400 ether, 400 ether, -1200, 1200);
        require(ids.length == 2, "Initial positions must open");
    }

    function actionOpen(uint8 actor, uint128 budget0, uint128 budget1, uint8 range) external {
        if (ids.length >= 8) return;
        int24 lower = range % 3 == 0 ? int24(-120) : int24(-1200);
        int24 upper = range % 3 == 2 ? int24(120) : -lower;
        _open(actor % 2, 1_000_000 + budget0 % (100 ether), 1_000_000 + budget1 % (100 ether), lower, upper);
    }

    function _open(uint256 actor, uint128 b0, uint128 b1, int24 lower, int24 upper) internal {
        uint256 before0 = token0.balanceOf(address(users[actor]));
        uint256 before1 = token1.balanceOf(address(users[actor]));
        ValariRouter.DepositQuote memory q = router.previewDeposit(poolId, b0, b1, lower, upper);
        (bool ok, bytes memory result) = users[actor].invoke(address(router), abi.encodeCall(router.openPosition,
            (poolId, b0, b1, lower, upper, q.liquidity, block.timestamp)));
        if (!ok) { opensCorrect = false; return; }
        (uint256 id, uint128 liquidity, uint256 a0, uint256 a1) = abi.decode(result, (uint256, uint128, uint256, uint256));
        ids.push(id);
        actorOf[id] = actor;
        opensCorrect = opensCorrect && liquidity == q.liquidity && a0 <= b0 && a1 <= b1
            && before0 - token0.balanceOf(address(users[actor])) == a0
            && before1 - token1.balanceOf(address(users[actor])) == a1;
    }

    function actionSwap(bool zeroForOne, uint128 amount) external {
        // Failed swaps when no liquidity is active are valid v4 outcomes.
        try manager.unlock(abi.encode(false, zeroForOne, 1 + uint256(amount) % (80 ether), uint256(0))) {} catch {}
    }

    function actionDonate(uint128 amount0, uint128 amount1) external {
        try manager.unlock(abi.encode(true, false, uint256(amount0) % (1 ether), uint256(amount1) % (1 ether))) {} catch {}
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool donate, bool zeroForOne, uint256 amount0, uint256 amount1) = abi.decode(data, (bool, bool, uint256, uint256));
        BalanceDelta delta = donate
            ? manager.donate(key, amount0, amount1, "")
            : manager.swap(key, SwapParams(zeroForOne, -int256(amount0), zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            manager.sync(currency);
            AuditToken(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) manager.take(currency, address(this), uint128(delta));
    }

    function actionCollect(uint8 index) external { _payout(ids[index % ids.length], false); }
    function actionExit(uint8 index) external { _payout(ids[index % ids.length], true); }

    function _payout(uint256 id, bool exit) internal {
        ValariRouter.PositionView memory beforePosition = router.getPosition(id);
        if (beforePosition.closed) return;
        AuditActor actor = users[actorOf[id]];
        uint256 before0 = token0.balanceOf(address(actor));
        uint256 before1 = token1.balanceOf(address(actor));
        uint256 credit0 = router.claimableCommission(router.feeRecipient(), address(token0));
        uint256 credit1 = router.claimableCommission(router.feeRecipient(), address(token1));
        bytes memory callData = exit
            ? abi.encodeCall(router.exitPosition, (id, uint128(beforePosition.amount0), uint128(beforePosition.amount1), block.timestamp))
            : abi.encodeCall(router.collectFees, (id, block.timestamp));
        (bool ok, bytes memory result) = actor.invoke(address(router), callData);
        if (!ok) { payoutsCorrect = false; return; }
        ValariRouter.Payout memory p = abi.decode(result, (ValariRouter.Payout));
        payoutsCorrect = payoutsCorrect
            && p.principal0 == (exit ? beforePosition.amount0 : 0)
            && p.principal1 == (exit ? beforePosition.amount1 : 0)
            && p.fees0 == beforePosition.fees0 && p.fees1 == beforePosition.fees1
            && p.commission0 == beforePosition.commission0 && p.commission1 == beforePosition.commission1
            && token0.balanceOf(address(actor)) - before0 == p.amount0
            && token1.balanceOf(address(actor)) - before1 == p.amount1
            && p.amount0 + p.commission0 == p.principal0 + p.fees0
            && p.amount1 + p.commission1 == p.principal1 + p.fees1
            && router.claimableCommission(router.feeRecipient(), address(token0)) == credit0 + p.commission0
            && router.claimableCommission(router.feeRecipient(), address(token1)) == credit1 + p.commission1;
    }

    function actionRotateRecipient(uint8 choice) external { router.setFeeRecipient(address(treasuries[choice % 2])); }

    function actionWithdraw(uint8 recipient, bool chooseToken1, uint256 amount) external {
        AuditActor actor = treasuries[recipient % 2];
        AuditToken token = chooseToken1 ? token1 : token0;
        uint256 credit = router.claimableCommission(address(actor), address(token));
        if (credit == 0) return;
        amount = 1 + amount % credit;
        uint256 beforeBalance = token.balanceOf(address(actor));
        (bool ok,) = actor.invoke(address(router), abi.encodeCall(router.withdrawCommission, (address(token), address(actor), amount)));
        payoutsCorrect = payoutsCorrect && ok && token.balanceOf(address(actor)) == beforeBalance + amount
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
        (bool stealCredit,) = wrongActor.invoke(address(router), abi.encodeCall(router.withdrawCommission, (address(token0), address(wrongActor), 1)));
        (bool rotate,) = wrongActor.invoke(address(router), abi.encodeCall(router.setFeeRecipient, (address(wrongActor))));
        accessCorrect = accessCorrect && !wrongUser && !privilegedOwner && !stealCredit && !rotate;
    }

    function actionDust(uint64 amount0, uint64 amount1) external {
        uint256 a0 = uint256(amount0) % 1000;
        uint256 a1 = uint256(amount1) % 1000;
        token0.transfer(address(router), a0);
        token1.transfer(address(router), a1);
        dust0 += a0;
        dust1 += a1;
    }

    function echidna_commission_is_backed_and_dust_preserved() external view returns (bool) {
        return token0.balanceOf(address(router)) == dust0 + router.totalClaimableCommission(address(token0))
            && token1.balanceOf(address(router)) == dust1 + router.totalClaimableCommission(address(token1))
            && router.totalClaimableCommission(address(token0)) == router.claimableCommission(address(treasuries[0]), address(token0)) + router.claimableCommission(address(treasuries[1]), address(token0))
            && router.totalClaimableCommission(address(token1)) == router.claimableCommission(address(treasuries[0]), address(token1)) + router.claimableCommission(address(treasuries[1]), address(token1));
    }

    function echidna_custody_and_cumulative_commission() external view returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            ValariRouter.PositionView memory p = router.getPosition(ids[i]);
            if (p.depositor != address(users[actorOf[ids[i]]]) || p.commissionAccrued0 != p.feesCollected0 / 10
                || p.commissionAccrued1 != p.feesCollected1 / 10) return false;
            if (p.closed ? p.exists || p.nftOwner != address(0) : !p.exists || p.nftOwner != address(router)
                || positions.getPositionLiquidity(ids[i]) != p.initialLiquidity) return false;
        }
        return true;
    }

    function echidna_allowances_are_cleared() external view returns (bool) {
        (uint160 a0,,) = permit.allowance(address(router), address(token0), address(positions));
        (uint160 a1,,) = permit.allowance(address(router), address(token1), address(positions));
        return a0 == 0 && a1 == 0 && token0.allowance(address(router), address(permit)) == 0
            && token1.allowance(address(router), address(permit)) == 0;
    }

    function echidna_token_supply_is_conserved() external view returns (bool) {
        return _balances(token0) == token0.totalSupply() && _balances(token1) == token1.totalSupply();
    }

    function _balances(AuditToken token) internal view returns (uint256 total) {
        total = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(positions)) + token.balanceOf(address(router)) + token.balanceOf(address(permit));
        for (uint256 i; i < 2; ++i) total += token.balanceOf(address(users[i])) + token.balanceOf(address(treasuries[i]));
    }

    function echidna_payouts_match_actual_balance_changes() external view returns (bool) { return payoutsCorrect; }
    function echidna_owner_and_outsiders_cannot_take_positions() external view returns (bool) { return accessCorrect; }
    function echidna_deposit_budget_refund_and_quote() external view returns (bool) { return opensCorrect; }
}
