// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {ValariRouter, IPermit2Source} from "../src/ValariRouter.sol";

/// @notice Deployment entrypoint using the exact checked-in 100-pool catalog.
/// @dev Select a signer through Foundry CLI. This script does not read private-key files.
contract DeployValariRouter is Script {
    using PoolIdLibrary for PoolKey;

    function run() external returns (ValariRouter router) {
        string memory config = vm.readFile("config/robinhood.json");
        require(
            block.chainid == 4663 && vm.parseJsonUint(config, ".chainId") == 4663, "Wrong chain"
        );
        IPositionManager manager = IPositionManager(vm.parseJsonAddress(config, ".positionManager"));
        IStateView state = IStateView(vm.parseJsonAddress(config, ".stateView"));
        require(
            address(manager.poolManager()) == vm.parseJsonAddress(config, ".poolManager"),
            "Wrong PoolManager"
        );
        require(
            address(IPermit2Source(address(manager)).permit2())
                == vm.parseJsonAddress(config, ".permit2"),
            "Wrong Permit2"
        );
        PoolKey[] memory keys = abi.decode(vm.parseJsonBytes(config, ".poolKeysAbi"), (PoolKey[]));
        bytes32[] memory ids = vm.parseJsonBytes32Array(config, ".poolIds");
        require(keys.length == 100 && ids.length == 100, "Expected 100 pools");
        for (uint256 i; i < keys.length; ++i) {
            require(PoolId.unwrap(keys[i].toId()) == ids[i], "Pool ID mismatch");
        }
        address usdg = vm.parseJsonAddress(config, ".usdg");

        vm.startBroadcast();
        router = new ValariRouter(manager, state, usdg, keys);
        vm.stopBroadcast();
        console2.log("ValariRouter:", address(router));
        console2.log("Pool count:", router.poolCount());
        console2.log("Owner:", router.owner());
        console2.log("Commission recipient:", router.feeRecipient());
    }
}
