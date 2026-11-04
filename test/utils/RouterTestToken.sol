// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @dev ERC20 with opt-in transfer tax and callback to exercise funding defenses.
contract RouterTestToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint256 public transferFeeBps;
    mapping(address => bool) public blockedRecipient;

    error RecipientBlocked(address recipient);
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function mint(address recipient, uint256 amount) external {
        totalSupply += amount;
        balanceOf[recipient] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function setTransferFee(uint256 bps) external {
        transferFeeBps = bps;
    }

    function setBlockedRecipient(address recipient, bool blocked) external {
        blockedRecipient[recipient] = blocked;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (blockedRecipient[to]) revert RecipientBlocked(to);
        if (callbackTarget != address(0) && !callbackAttempted) {
            callbackAttempted = true;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        uint256 fee = amount * transferFeeBps / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}
