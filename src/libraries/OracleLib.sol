// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @notice This library is used to check the Chainlink Oracle for stale data.
 * If the data is stale, the contract will revert. and render the DESC unusable.
 * We want the DSCEngine to freeze the contract if the data is stale.
 */

library OracleLib {
    error OracleLib__StalePrice();

    uint256 public constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(
        AggregatorV3Interface _priceFeed
    ) public view returns (uint80, int256, uint256, uint256, uint80) {
        (
            uint80 roundID,
            int256 price,
            uint256 startedAt,
            uint256 timeStamp,
            uint80 answeredInRound
        ) = _priceFeed.latestRoundData();

        // check the time stamp
        uint256 timeElapsed = block.timestamp - startedAt;
        if (timeElapsed > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return (roundID, price, startedAt, timeStamp, answeredInRound);
    }
}
