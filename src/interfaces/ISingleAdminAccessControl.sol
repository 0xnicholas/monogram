// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

interface ISingleAdminAccessControl {
    error InvalidAdminChange();
    error NotPendingAdmin();

    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event AdminTransferRequested(address indexed oldAdmin, address indexed newAdmin);

    /// @notice 当前 admin（ERC-5313 `owner()`）
    function owner() external view returns (address);

    /// @notice 待接受的 admin；无待接受移交时返回零地址
    function pendingAdmin() external view returns (address);

    function transferAdmin(address newAdmin) external;

    function acceptAdmin() external;
}
