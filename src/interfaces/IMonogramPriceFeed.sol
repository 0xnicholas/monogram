// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

interface IMonogramPriceFeed {
    error AssetNotConfigured();
    error StalePythPrice();
    error StaleChainlinkPrice();
    error OracleDeviationExceeded();
    error InvalidPythPrice();
    error PriceConfidenceTooWide();

    event OracleConfigSet(
        address indexed asset, bytes32 pythFeed, address chainlinkFeed, uint128 maxAge, uint128 maxDeviation
    );
    event OracleConfigRemoved(address indexed asset);

    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt);
    function getPriceAndTimestamp(address asset) external view returns (uint256, uint256);
    function setOracleConfig(
        address asset,
        bytes32 pythFeed,
        address chainlinkFeed,
        uint128 maxAge,
        uint128 maxDeviation
    ) external;
    function removeOracleConfig(address asset) external;
}
