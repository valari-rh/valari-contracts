// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @dev Stand-ins for the contracts ValariRouterV3's constructor and addPool consult.
/// Manticore cannot execute the real v4 managers (transient storage, Cancun opcodes), so the
/// symbolic runs cover the router's own entry checks, access control and catalog logic only.
contract MockCode {
    uint256 public marker = 1;
}

contract MockPositionManager {
    address public poolManager;
    address public permit2;

    constructor(address poolManager_, address permit2_) {
        poolManager = poolManager_;
        permit2 = permit2_;
    }
}

contract MockStateView {
    address public poolManager;

    constructor(address poolManager_) {
        poolManager = poolManager_;
    }

    /// @dev Every pool reads as initialized at price 1.
    function getSlot0(bytes32) external pure returns (uint160, int24, uint24, uint24) {
        return (uint160(1 << 96), 0, 0, 0);
    }
}
