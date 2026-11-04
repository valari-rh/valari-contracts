// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {ValariRouterV3, IPermit2Source} from "../src/ValariRouterV3.sol";

/// @notice Deploys ValariRouterV3 with the curated catalog: exactly the pools the Valari
/// frontend lists (config/robinhood-curated.json, written by tools/curated-catalog.mjs from
/// ../valari/src/lib/pools.json). The full 100-pool catalog the deployed routers carry is
/// config/robinhood.json; pools can be appended later with AddValariRouterV3Pools.
/// @dev Select a signer through Foundry CLI. This script does not read private-key files.
/// VALARI_POOLS_CONFIG optionally names another catalog under config/ (any number of
/// pools up to MAX_INITIAL_POOLS).
contract DeployValariRouterV3 is Script {
    using PoolIdLibrary for PoolKey;

    function run() external returns (ValariRouterV3 router) {
        string memory path =
            vm.envOr("VALARI_POOLS_CONFIG", string("config/robinhood-curated.json"));
        string memory config = vm.readFile(path);
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
        // The constructor itself refuses more than MAX_INITIAL_POOLS.
        require(keys.length == ids.length && keys.length != 0, "Pool list mismatch");
        for (uint256 i; i < keys.length; ++i) {
            require(PoolId.unwrap(keys[i].toId()) == ids[i], "Pool ID mismatch");
        }
        address usdg = vm.parseJsonAddress(config, ".usdg");

        vm.startBroadcast();
        router = new ValariRouterV3(manager, state, usdg, keys);
        vm.stopBroadcast();

        require(router.poolCount() == ids.length, "Catalog size mismatch");
        for (uint256 i; i < ids.length; ++i) {
            require(router.getPoolIds(i, 1)[0] == ids[i], "Catalog order mismatch");
        }
        console2.log("ValariRouterV3:", address(router));
        console2.log("Pool count:", router.poolCount());
        console2.log("Owner:", router.owner());
        console2.log("Commission recipient:", router.feeRecipient());
    }
}
