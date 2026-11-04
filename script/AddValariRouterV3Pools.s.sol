// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ValariRouterV3} from "../src/ValariRouterV3.sol";

/// @notice Appends every catalog pool the router does not list yet. Safe to re-run: pools
/// already listed are skipped, so it brings a router up to date with a grown catalog.
/// A stock may appear more than once, under different fee tiers.
/// @dev VALARI_ROUTER_V3 is the deployed router; the signer must be its owner.
/// VALARI_POOLS_CONFIG optionally names another catalog under config/ (same format as
/// config/robinhood.json, any number of pools).
contract AddValariRouterV3Pools is Script {
    using PoolIdLibrary for PoolKey;

    function run() external returns (uint256 added) {
        ValariRouterV3 router = ValariRouterV3(vm.envAddress("VALARI_ROUTER_V3"));
        string memory path = vm.envOr("VALARI_POOLS_CONFIG", string("config/robinhood.json"));
        string memory config = vm.readFile(path);
        require(
            block.chainid == 4663 && vm.parseJsonUint(config, ".chainId") == 4663, "Wrong chain"
        );
        require(address(router).code.length != 0, "No router at VALARI_ROUTER_V3");
        // Only V3 has this getter: the earlier routers would otherwise pass every check
        // below and report "0 pools added" against the wrong contract.
        try router.MAX_PAYOUT_DUST() returns (uint256) {}
        catch {
            revert("VALARI_ROUTER_V3 is not a ValariRouterV3");
        }
        require(
            address(router.positionManager()) == vm.parseJsonAddress(config, ".positionManager"),
            "Wrong PositionManager"
        );
        require(
            address(router.stateView()) == vm.parseJsonAddress(config, ".stateView"),
            "Wrong StateView"
        );
        require(router.usdg() == vm.parseJsonAddress(config, ".usdg"), "Wrong USDG");
        PoolKey[] memory keys = abi.decode(vm.parseJsonBytes(config, ".poolKeysAbi"), (PoolKey[]));
        bytes32[] memory ids = vm.parseJsonBytes32Array(config, ".poolIds");
        require(keys.length == ids.length, "Pool list mismatch");

        // Decide everything before sending anything, so a bad catalog sends no transaction.
        bool[] memory missing = new bool[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            require(PoolId.unwrap(keys[i].toId()) == ids[i], "Pool ID mismatch");
            // getPoolKey reverts for a pool the router does not list.
            try router.getPoolKey(ids[i]) returns (PoolKey memory) {}
            catch {
                missing[i] = true;
            }
        }

        uint256 countBefore = router.poolCount();
        vm.startBroadcast();
        for (uint256 i; i < keys.length; ++i) {
            if (!missing[i]) continue;
            require(router.addPool(keys[i]) == ids[i], "Unexpected pool ID");
            ++added;
        }
        vm.stopBroadcast();

        require(router.poolCount() == countBefore + added, "Catalog size mismatch");
        console2.log("ValariRouterV3:", address(router));
        console2.log("Pools added:", added);
        console2.log("Pool count:", router.poolCount());
    }
}
