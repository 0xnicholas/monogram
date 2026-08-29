// SPDX-License-Identifier: GPL-3.0
// Derived from Ethena's USDeSilo (GPL-3.0), see
// https://github.com/code-423n4/2023-10-ethena/blob/main/contracts/USDeSilo.sol
// Modifications for Monogram: token named M_TOKEN, transfers use SafeERC20.
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IUnstakingSilo.sol";

/**
 * @title UnstakingSilo
 * @notice 冷却期期间隔离解质押资产的合约。只有 StakedM 可以从中转出资产，
 *         使冷却中的资产即时退出 StakedM.totalAssets（修复稀释与偿付缺陷，见 ADR-0007）。
 */
contract UnstakingSilo is IUnstakingSilo {
    using SafeERC20 for IERC20;

    address public immutable STAKING_VAULT;
    IERC20 public immutable M_TOKEN;

    constructor(address stakingVault, address mToken) {
        STAKING_VAULT = stakingVault;
        M_TOKEN = IERC20(mToken);
    }

    modifier onlyStakingVault() {
        if (msg.sender != STAKING_VAULT) revert OnlyStakingVault();
        _;
    }

    function withdraw(address to, uint256 amount) external onlyStakingVault {
        M_TOKEN.safeTransfer(to, amount);
    }
}
