// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
}
