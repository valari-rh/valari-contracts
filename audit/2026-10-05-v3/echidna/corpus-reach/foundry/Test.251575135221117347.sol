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
        Target.actionOpen(0, 0, 0, 0, 0);
        _setUpActor(USER1);
        Target.actionOpenAfterPriceMove(0, 0, false, 48775640112049816133350, 228833270976435085295180, 218765105406957998647287722, 0);
        _setUpActor(USER1);
        Target.actionExit(1, false);
        _setUpActor(USER1);
        Target.actionWithdraw(0, 0, 0);
        _setUpActor(USER1);
        Target.actionCollect(2, false);
        _setUpActor(USER1);
        Target.actionExit(0, false);
        vm.stopPrank();
        vm.prank(address(0x10000));
        assertFalse(Target.echidna_reach_commission_charged_and_withdrawn());
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
