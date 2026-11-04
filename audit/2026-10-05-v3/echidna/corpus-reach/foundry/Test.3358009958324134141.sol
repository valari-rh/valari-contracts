// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

contract FoundryTest is Test {
    address constant USER1 = address(0x10000);

    // TODO: Replace with your actual contract instance
    RouterEchidnaV3Reach Target;

  function setUp() public {
      // TODO: Initialize your contract here
      Target = new RouterEchidnaV3Reach();
  }

  function test_replay() public {
        _setUpActor(USER1);
        Target.actionSetDeposits(255, true);
        _setUpActor(USER1);
        Target.actionCollect(6, true);
        _setUpActor(USER1);
        Target.actionOpen(0, 57, 133269, 644024615643662069834925103981291, 0);
        _setUpActor(USER1);
        Target.actionSetDeposits(0, false);
        _setUpActor(USER1);
        Target.actionSetEject(18, true);
        _setUpActor(USER1);
        Target.actionOpen(0, 0, 41422017428266254, 1298442179526651829725255251454158, 0);
        _setUpActor(USER1);
        Target.actionExit(1, true);
        _setUpActor(USER1);
        Target.actionEject(2, false);
        _setUpActor(USER1);
        Target.actionEject(0, false);
        vm.stopPrank();
        vm.prank(address(0x10000));
        assertFalse(Target.echidna_reach_refused_ejected_and_paid_elsewhere());
  }

  function _setUpActor(address actor) internal {
      vm.startPrank(actor);
      // Add any additional actor setup here if needed
  }

  function _delay(uint256 timeInSeconds, uint256 numBlocks) internal {
      vm.warp(block.timestamp + timeInSeconds);
      vm.roll(block.number + numBlocks);
  }

}
