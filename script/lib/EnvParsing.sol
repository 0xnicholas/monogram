// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

/**
 * @title EnvParsing — forge script 环境变量的 CSV 解析
 * @notice 部署脚本与部署后校验脚本共用同一份解析（避免两处实现漂移）。
 * @dev 当前是严格解析：地址项必须恰好 42 字符、不含空白；`"0xA, 0xB"` 这种带空格的写法会
 *      revert("invalid address length")。容忍空白与空项属于工具层硬化（GitHub issue #23）。
 */
library EnvParsing {
    function parseAddresses(string memory csv) internal pure returns (address[] memory) {
        if (bytes(csv).length == 0) return new address[](0);
        bytes memory data = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == ",") count++;
        }
        address[] memory addrs = new address[](count);
        uint256 idx = 0;
        uint256 last = 0;
        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == ",") {
                bytes memory chunk = new bytes(i - last);
                for (uint256 j = 0; j < i - last; j++) {
                    chunk[j] = data[last + j];
                }
                addrs[idx] = parseAddress(string(chunk));
                idx++;
                last = i + 1;
            }
        }
        return addrs;
    }

    function parseHex32List(string memory csv) internal pure returns (bytes32[] memory) {
        if (bytes(csv).length == 0) return new bytes32[](0);
        bytes memory data = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == ",") count++;
        }
        bytes32[] memory items = new bytes32[](count);
        uint256 idx = 0;
        uint256 last = 0;
        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == ",") {
                bytes memory chunk = new bytes(i - last);
                for (uint256 j = 0; j < i - last; j++) {
                    chunk[j] = data[last + j];
                }
                items[idx] = parseHex32(string(chunk));
                idx++;
                last = i + 1;
            }
        }
        return items;
    }

    function parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42, "invalid address length");
        uint256 addr = 0;
        for (uint256 i = 2; i < b.length; i++) {
            addr = addr * 16 + _hexDigit(b[i]);
        }
        return address(uint160(addr));
    }

    function parseHex32(string memory s) internal pure returns (bytes32) {
        bytes memory b = bytes(s);
        require(b.length > 2 && b.length <= 66, "invalid bytes32 length");
        uint256 value = 0;
        for (uint256 i = 2; i < b.length; i++) {
            value = value * 16 + _hexDigit(b[i]);
        }
        return bytes32(value);
    }

    function _hexDigit(bytes1 c) private pure returns (uint256) {
        if (c >= 0x30 && c <= 0x39) return uint256(uint8(c)) - 0x30;
        if (c >= 0x41 && c <= 0x46) return uint256(uint8(c)) - 0x41 + 10;
        if (c >= 0x61 && c <= 0x66) return uint256(uint8(c)) - 0x61 + 10;
        revert("invalid hex char");
    }
}
