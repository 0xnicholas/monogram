// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/MonogramPriceFeed.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";
import "../src/interfaces/IPyth.sol";
import "../src/interfaces/AggregatorV3Interface.sol";

contract MockPyth is IPyth {
    mapping(bytes32 => Price) public prices;

    function setPrice(bytes32 feedId, Price memory price) external {
        prices[feedId] = price;
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        return prices[id];
    }
}

contract MockChainlinkFeed is AggregatorV3Interface {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;

    function setAnswer(int256 _answer, uint8 _decimals) external {
        answer = _answer;
        decimals = _decimals;
        updatedAt = block.timestamp;
    }

    function setAnswerAndTime(int256 _answer, uint8 _decimals, uint256 _updatedAt) external {
        answer = _answer;
        decimals = _decimals;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }
}

contract MonogramPriceFeedTest is Test {
    MonogramPriceFeed public priceFeed;
    MockPyth public mockPyth;
    MockChainlinkFeed public mockCl;

    address public admin = makeAddr("admin");
    address public oracleAdmin = makeAddr("oracleAdmin");

    bytes32 public constant FEED_ID = keccak256("ETH/USD");

    function setUp() public {
        mockPyth = new MockPyth();
        mockCl = new MockChainlinkFeed();

        vm.startPrank(admin);
        priceFeed = new MonogramPriceFeed(admin, address(mockPyth));
        priceFeed.grantRole(priceFeed.ORACLE_ADMIN_ROLE(), oracleAdmin);
        vm.stopPrank();

        // Set mock Pyth price at $3000 ETH, expo -8
        mockPyth.setPrice(FEED_ID, IPyth.Price({
            price: 3000_00000000,
            conf: 1,
            expo: -8,
            publishTime: uint64(block.timestamp)
        }));

        // Set mock Chainlink price at $3000, decimals 8
        mockCl.setAnswer(3000_00000000, 8);
    }

    function test_Deployment() public view {
        assertTrue(priceFeed.hasRole(priceFeed.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_AssetNotConfigured() public {
        vm.expectRevert(IMonogramPriceFeed.AssetNotConfigured.selector);
        priceFeed.getPrice(makeAddr("unknown"));
    }

    function test_SetOracleConfig() public {
        vm.prank(oracleAdmin);
        priceFeed.setOracleConfig(makeAddr("ETH"), FEED_ID, address(mockCl), 3600, 50);
        (,,, , bool exists) = priceFeed.configs(makeAddr("ETH"));
        assertTrue(exists);
    }

    function test_SetOracleConfig_NotAuthorized() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        priceFeed.setOracleConfig(makeAddr("ETH"), FEED_ID, address(mockCl), 3600, 50);
    }

    function test_RemoveOracleConfig() public {
        vm.startPrank(oracleAdmin);
        priceFeed.setOracleConfig(makeAddr("ETH"), FEED_ID, address(mockCl), 3600, 50);
        priceFeed.removeOracleConfig(makeAddr("ETH"));
        vm.stopPrank();
        (,,, , bool exists) = priceFeed.configs(makeAddr("ETH"));
        assertFalse(exists);
    }

    function test_RemoveOracleConfig_NotConfigured() public {
        vm.prank(oracleAdmin);
        vm.expectRevert(IMonogramPriceFeed.AssetNotConfigured.selector);
        priceFeed.removeOracleConfig(makeAddr("ETH"));
    }

    function test_OracleDeviationExceeded() public {
        vm.prank(oracleAdmin);
        priceFeed.setOracleConfig(makeAddr("ETH"), FEED_ID, address(mockCl), 3600, 1); // 0.01% deviation

        // Set Chainlink to $3100 (vs Pyth $3000 = ~3.3% deviation)
        mockCl.setAnswer(3100_00000000, 8);

        vm.expectRevert(IMonogramPriceFeed.OracleDeviationExceeded.selector);
        priceFeed.getPrice(makeAddr("ETH"));
    }
}
