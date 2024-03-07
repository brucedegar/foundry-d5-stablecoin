// This handler is going to narrow down the way we call funtions in the DecentralizedStableCoin contract.
// setup the function and code
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timeMintCalled;
    // keep track the  list of customers have deposited collateral
    address[] public customersWithCollateralDeposited;

    MockV3Aggregator wethUsdPriceFeed;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        address[] memory tokenAddresses = dsce.getTokenAddresses();
        weth = ERC20Mock(tokenAddresses[0]);
        wbtc = ERC20Mock(tokenAddresses[1]);

        wethUsdPriceFeed = MockV3Aggregator(
            dsce.getCollateralTokenPriceFeed(address(weth))
        );
    }

    function depositCollateral(
        uint256 _collateralSeed,
        uint256 _amountCollateral
    ) public {
        ERC20Mock collateral = ERC20Mock(
            _getCollateralFromSeed(_collateralSeed)
        );

        _amountCollateral = bound(_amountCollateral, 1, MAX_DEPOSIT_SIZE);

        // [2959] ERC20Mock::transferFrom(Handler: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], DSCEngine: [0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512], 14585671926021096603573509884 [1.458e28])
        // │   │   └─ ← ERC20InsufficientAllowance(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512, 0, 14585671926021096603573509884 [1.458e28])
        // So it means we need to approve the amount first
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, _amountCollateral);
        collateral.approve(address(dsce), _amountCollateral);

        // Pickup random value from the fuzzer for _collateralSeed and _amountCollateral
        dsce.depositCollateral(address(collateral), _amountCollateral);

        vm.stopPrank();
        customersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(
        uint256 _collateralSeed,
        uint256 _amountCollateral
    ) public {
        ERC20Mock collateral = ERC20Mock(
            _getCollateralFromSeed(_collateralSeed)
        );

        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(
            msg.sender,
            address(collateral)
        );

        if (maxCollateralToRedeem == 0) {
            return;
        }

        _amountCollateral = bound(_amountCollateral, 1, maxCollateralToRedeem);

        // Pickup random value from the fuzzer for _collateralSeed and _amountCollateral
        dsce.redeemCollateral(address(collateral), _amountCollateral);
    }

    // Helper funtion
    function _getCollateralFromSeed(
        uint256 _collateralSeed
    ) private view returns (ERC20Mock) {
        if (_collateralSeed % 2 == 0) {
            return ERC20Mock(weth);
        } else {
            return ERC20Mock(wbtc);
        }
    }

    function mintDsc(uint256 _amount, uint256 addressSeed) public {
        // make sure the user used to mint DSC is same with the user that deposited collateral
        // make sure the user has enough collateral to mint
        // ????
        if (customersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = customersWithCollateralDeposited[
            addressSeed % customersWithCollateralDeposited.length
        ];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) -
            int256(totalDscMinted);
        if (maxDscToMint <= 0) {
            return;
        }

        _amount = bound(_amount, 0, uint256(maxDscToMint));
        if (_amount == 0) {
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(_amount);
        vm.stopPrank();
        timeMintCalled++;
    }

    /*
    function updateCollateralPrice(uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice));
        wethUsdPriceFeed.updateAnswer(newPriceInt);
    }
    */
}
