// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ValariRouter} from "../src/ValariRouter.sol";

interface IERC721PermitV4 {
    function permit(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external payable;
}

/// @notice Probes the DEPLOYED router and PositionManager: nobody but the router can touch
/// a custodied position directly through Uniswap, by any of the PositionManager's paths.
contract ValariRouterLiveCustodyProbe is Test {
    ValariRouter internal constant ROUTER =
        ValariRouter(0x669092861489E6abdCB3aaA16994cF31253967b7);
    bytes32 internal constant GOOGL_POOL =
        0xd4ecb79fdc521d7725d22b33ed43cb4e47aa96bfad76aa29577e3151f723ac5e;
    address internal user = makeAddr("probe-user");
    address internal outsider = makeAddr("probe-outsider");

    function testLiveProbeOutsiderCannotTouchCustodiedPosition() public {
        if (!vm.envOr("RUN_ROBINHOOD_FORK", false)) return;
        vm.createSelectFork(vm.envOr("PROBE_RPC", string("robinhood")));
        IPositionManager pm = ROUTER.positionManager();
        PoolKey memory key = ROUTER.getPoolKey(GOOGL_POOL);
        address stock = Currency.unwrap(key.currency0);
        address usdg = ROUTER.usdg();
        (, int24 tick,,) = ROUTER.stateView().getSlot0(PoolId.wrap(GOOGL_POOL));
        int24 center = tick / key.tickSpacing * key.tickSpacing;

        deal(stock, user, 10 ether);
        deal(usdg, user, 10_000e6);
        vm.startPrank(user);
        IERC20(stock).approve(address(ROUTER), 10 ether);
        IERC20(usdg).approve(address(ROUTER), 10_000e6);
        ValariRouter.DepositQuote memory q =
            ROUTER.previewDeposit(GOOGL_POOL, 10 ether, 10_000e6, center - 1200, center + 1200);
        (uint256 tokenId,,,) = ROUTER.openPosition(
            GOOGL_POOL,
            10 ether,
            10_000e6,
            center - 1200,
            center + 1200,
            q.liquidity,
            block.timestamp
        );
        vm.stopPrank();
        assertEq(IERC721(address(pm)).ownerOf(tokenId), address(ROUTER));

        bytes[] memory params = new bytes[](2);
        params[1] = abi.encode(key.currency0, key.currency1, outsider);

        // INCREASE_LIQUIDITY(0) credits the caller with the position's fees if unguarded.
        params[0] = abi.encode(tokenId, uint256(0), type(uint128).max, type(uint128).max, bytes(""));
        _expectDirectCallReverts(pm, Actions.INCREASE_LIQUIDITY, params, "increase");
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        _expectDirectCallReverts(pm, Actions.DECREASE_LIQUIDITY, params, "decrease");
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        _expectDirectCallReverts(pm, Actions.BURN_POSITION, params, "burn");

        // The same attempts from the depositor: only the router's own API may act.
        vm.startPrank(user);
        (bool ok,) = address(pm)
            .call(
                abi.encodeCall(
                    pm.modifyLiquidities,
                    (
                        abi.encode(
                            abi.encodePacked(
                                uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)
                            ),
                            params
                        ),
                        block.timestamp
                    )
                )
            );
        assertFalse(ok, "depositor bypassed the router");
        vm.stopPrank();

        vm.startPrank(outsider);
        (ok,) = address(pm)
            .call(abi.encodeCall(IERC721.transferFrom, (address(ROUTER), outsider, tokenId)));
        assertFalse(ok, "transferFrom");
        (ok,) = address(pm).call(abi.encodeCall(IERC721.approve, (outsider, tokenId)));
        assertFalse(ok, "approve");
        // ERC721Permit_v4 accepts EIP-1271 signatures from contract owners; the router
        // exposes no isValidSignature and no fallback, so this must fail.
        (ok,) = address(pm)
            .call(
                abi.encodeCall(
                    IERC721PermitV4.permit, (outsider, tokenId, block.timestamp, 0, new bytes(65))
                )
            );
        assertFalse(ok, "erc721 permit");
        (ok,) = address(pm)
            .call(
                abi.encodeCall(IERC721PermitV4.permit, (outsider, tokenId, block.timestamp, 0, ""))
            );
        assertFalse(ok, "erc721 permit, empty signature");
        IAllowanceTransfer permit2 = ROUTER.permit2();
        IAllowanceTransfer.PermitSingle memory single = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: usdg, amount: type(uint160).max, expiration: type(uint48).max, nonce: 0
            }),
            spender: outsider,
            sigDeadline: block.timestamp
        });
        (ok,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
                    address(ROUTER),
                    single,
                    new bytes(65)
                )
            );
        assertFalse(ok, "permit2 permit");
        vm.stopPrank();

        // Nothing is left approved after the deposit.
        assertEq(IERC20(stock).allowance(address(ROUTER), address(permit2)), 0);
        assertEq(IERC20(usdg).allowance(address(ROUTER), address(permit2)), 0);
        assertEq(IERC721(address(pm)).getApproved(tokenId), address(0));
        assertEq(IERC721(address(pm)).ownerOf(tokenId), address(ROUTER));

        // And the depositor still exits normally.
        ValariRouter.PositionView memory p = ROUTER.getPosition(tokenId);
        vm.prank(user);
        ROUTER.exitPosition(tokenId, uint128(p.amount0), uint128(p.amount1), block.timestamp);
        emit log_named_uint("probed at block", block.number);
    }

    function _expectDirectCallReverts(
        IPositionManager pm,
        uint256 action,
        bytes[] memory params,
        string memory label
    ) private {
        vm.prank(outsider);
        (bool ok,) = address(pm)
            .call(
                abi.encodeCall(
                    pm.modifyLiquidities,
                    (
                        abi.encode(
                            abi.encodePacked(uint8(action), uint8(Actions.TAKE_PAIR)), params
                        ),
                        block.timestamp
                    )
                )
            );
        assertFalse(ok, label);
    }
}
