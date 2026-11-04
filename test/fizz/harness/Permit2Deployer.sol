// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

/// @notice Thin wrapper so the suite can etch canonical Permit2 bytecode at its fixed address
///         (0x000000000022D473030F116dDEE9F6B43aC78BA3) exactly like the project's own test fixture
///         and the prior Echidna harness, without inheriting forge-std `Script` (and its `vm`
///         member) into `Base.sol`, where `vm` is the hevm cheatcode constant.
contract Permit2Deployer is DeployPermit2 {}
