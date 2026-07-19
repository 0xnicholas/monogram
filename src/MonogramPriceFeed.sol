// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IMonogramPriceFeed.sol";
import "./interfaces/IPyth.sol";
import "./interfaces/AggregatorV3Interface.sol";

contract MonogramPriceFeed is IMonogramPriceFeed, AccessControl {
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");

    struct OracleConfig {
        bytes32 pythFeed;
        address chainlinkFeed;
        uint128 maxAge;
        uint128 maxDeviation;
        bool exists;
    }

    mapping(address asset => OracleConfig) public configs;
    address public pyth;

    constructor(address admin, address _pyth) {
        if (_pyth == address(0)) revert();
        pyth = _pyth;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ADMIN_ROLE, admin);
    }

    function setPyth(address _pyth) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_pyth == address(0)) revert();
        pyth = _pyth;
    }

    function getPriceAndTimestamp(address asset) external view override returns (uint256, uint256) {
        return getPrice(asset);
    }

    function getPrice(address asset) public view override returns (uint256 price, uint256 updatedAt) {
        OracleConfig storage cfg = configs[asset];
        if (!cfg.exists) revert AssetNotConfigured();

        IPyth pyth = IPyth(_getPythAddress());
        AggregatorV3Interface clFeed = AggregatorV3Interface(cfg.chainlinkFeed);

        (uint256 pythPrice, uint256 pythTime) = _readPyth(pyth, cfg.pythFeed);
        (uint256 clPrice, uint256 clTime) = _readChainlink(clFeed);

        if (block.timestamp - pythTime > cfg.maxAge) revert StalePythPrice();
        if (block.timestamp - clTime > cfg.maxAge) revert StaleChainlinkPrice();

        uint256 deviation = _bpsDiff(pythPrice, clPrice);
        if (deviation > cfg.maxDeviation) revert OracleDeviationExceeded();

        price = (pythPrice + clPrice) / 2;
        updatedAt = block.timestamp;
    }

    function setOracleConfig(
        address asset,
        bytes32 pythFeed,
        address chainlinkFeed,
        uint128 maxAge,
        uint128 maxDeviation
    ) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (asset == address(0)) revert();
        if (chainlinkFeed == address(0)) revert();
        if (maxAge == 0 || maxDeviation == 0) revert();

        configs[asset] = OracleConfig({
            pythFeed: pythFeed,
            chainlinkFeed: chainlinkFeed,
            maxAge: maxAge,
            maxDeviation: maxDeviation,
            exists: true
        });

        emit OracleConfigSet(asset, pythFeed, chainlinkFeed, maxAge, maxDeviation);
    }

    function removeOracleConfig(address asset) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (!configs[asset].exists) revert AssetNotConfigured();
        delete configs[asset];
        emit OracleConfigRemoved(asset);
    }

    function _getPythAddress() internal view virtual returns (address) {
        return pyth;
    }

    function _readPyth(IPyth pyth, bytes32 feedId) internal view returns (uint256 price, uint256 publishTime) {
        IPyth.Price memory p = pyth.getPriceUnsafe(feedId);
        int256 exponent = int256(p.expo) + 18;
        if (exponent >= 0) {
            price = uint256(int256(p.price) * int256(10 ** uint256(exponent)));
        } else {
            price = uint256(int256(p.price) / int256(10 ** uint256(-exponent)));
        }
        publishTime = p.publishTime;
    }

    function _readChainlink(AggregatorV3Interface feed) internal view returns (uint256 price, uint256 updatedAt) {
        (, int256 answer,, uint256 clUpdatedAt,) = feed.latestRoundData();
        if (answer < 0) revert();
        uint8 clDecimals = feed.decimals();
        if (clDecimals <= 18) {
            price = uint256(answer) * (10 ** (18 - clDecimals));
        } else {
            price = uint256(answer) / (10 ** (clDecimals - 18));
        }
        updatedAt = clUpdatedAt;
    }

    function _bpsDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        uint256 base = a > b ? a : b;
        if (base == 0) return 0;
        return (diff * 10_000) / base;
    }
}
