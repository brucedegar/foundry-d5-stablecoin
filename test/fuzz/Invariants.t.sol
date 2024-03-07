// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Have our variants aka properties
// what are our variants?
// 1. Total supply of DSC token should be less than the total value of collateral
// 2. getter view function should never revert
// 3.

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (, , weth, wbtc, ) = config.activeNetworkConfig();

        // set target contract
        //targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler)); // -> with this we can ONLY call the functions of the handler

        // we need to define the sequence of the functions like dont call redeemCollateral unless there is some collateral
    }

    // 1. Total supply of DSC token should be less than the total value of collateral
    function invariant_protocolTotalSupplyLessThanTotalValueOfCollateral()
        public
        view
    {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 wbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, wethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

        console.log("wethValue: ", wethValue);
        console.log("wbtcValue: ", wbtcValue);
        console.log("Total Supply: ", totalSupply);
        console.log("Time of mint called: ", handler.timeMintCalled());

        assert(totalSupply <= wethValue + wbtcValue);
    }

    function invariant_getterViewFunctionShouldNeverRevert() public view {
        // we need to call all the getter view functions of the handler
        // and make sure they never revert
        dsce.getPrecision();
        dsce.getTokenAddresses();
        dsce.getAdditionalFeedPrecision();
    }
}
