// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IStakedM.sol";
import "./interfaces/IM.sol";

contract StakingRewardsDistributor is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IStakedM public immutable stakedM;
    IM public immutable m;

    uint256 public constant DISTRIBUTION_INTERVAL = 1 days;
    uint256 public lastDistribution;

    error TooFrequent();

    event RewardsDistributed(uint256 amount, uint256 timestamp);

    constructor(IStakedM _stakedM, IM _m, address _admin) {
        stakedM = _stakedM;
        m = _m;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function distribute(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (lastDistribution != 0 && block.timestamp < lastDistribution + DISTRIBUTION_INTERVAL) revert TooFrequent();

        IERC20(address(m)).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(address(m)).approve(address(stakedM), amount);
        stakedM.transferInRewards(amount);

        lastDistribution = block.timestamp;
        emit RewardsDistributed(amount, block.timestamp);
    }

    function recoverERC20(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
