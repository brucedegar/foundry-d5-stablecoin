// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address token,
        uint256 amount
    );
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine public engine;
    HelperConfig helperConfig;

    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = address(1);
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100;
    uint256 public constant AMOUNT_TO_MINT_BROKEN = 19000;

    //anonymousuint256 deployerKey;
    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();

        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, ) = helperConfig
            .activeNetworkConfig();

        // Mint 10 ether for current user
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    // Constructor Tests

    address[] public priceFeeds;
    address[] public tokens;

    function testRevertIfTokenLenghthDoesntMatchPriceFeedLength() public {
        priceFeeds.push(wbtcUsdPriceFeed);
        priceFeeds.push(wethUsdPriceFeed);
        tokens.push(weth);

        vm.expectRevert(
            DSCEngine
                .DSCEngine_TokenAndPriceAddressesShouldHaveSameLength
                .selector
        );
        new DSCEngine(tokens, priceFeeds, address(dsc));
    }

    // Prices Tests

    function testGetGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // 100 / 2000 = 0.05
        uint256 expectedAmount = 0.05 ether;

        uint256 actualAmount = engine.getTokenAmountFromDscUsd(weth, usdAmount);
        console.log("actualAmount: ", actualAmount);
        assert(actualAmount == expectedAmount);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000 = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        console.log("actualUsd: ", actualUsd);
        assert(actualUsd == expectedUsd);
    }

    function testRevertDepositAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testAllowDespositToken() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        address invalidToken = makeAddr("invalidAddress");
        engine.depositCollateral(invalidToken, 10);
        vm.stopPrank();
    }

    function testRevertWithUnapprovaedCollateral() public {
        ERC20Mock randomeToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        engine.depositCollateral(address(randomeToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositeCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositeCollateralAndGetAccountInfo()
        public
        depositeCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);

        // Assumed that the USER already deposited 10 ether (AMOUNT_COLLATERAL)
        assertEq(
            engine.getTotalCollateralForTokenAndUser(USER, weth),
            AMOUNT_COLLATERAL
        );

        console.log("collateralValueInUsd: ", collateralValueInUsd);
        // expected collateralValueInUsd = 10 * 2000 = 20,000
        // 20,000,000,000,000,000,000,000 = 20,000 e18

        uint256 expectedDepositedAmount = engine.getTokenAmountFromDscUsd(
            weth,
            collateralValueInUsd
        );

        // expectedDepositedAmount = 10
        // 10,000,000,000,000,000,000 = 10 e18
        console.log("expectedDepositedAmount: ", expectedDepositedAmount);

        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    // Test case for method DSCEngine.sol's depositCollateralAndMintDsc
    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            AMOUNT_TO_MINT
        );
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);

        console.log("totalDscMinted: ", totalDscMinted);
        console.log("collateralValueInUsd: ", collateralValueInUsd);

        assertEq(totalDscMinted, AMOUNT_TO_MINT);
        uint256 expectedDepositedAmount = engine.getTokenAmountFromDscUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    function testRevertMintDscIfHealthFactorIsBroken() public {
        (, int256 price, , , ) = MockV3Aggregator(wethUsdPriceFeed)
            .latestRoundData();

        amountToMint =
            (amountCollateral *
                (uint256(price) * engine.getAdditionalFeedPrecision())) /
            engine.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);

        uint256 expectedHealthFactor = engine.calculateHealthFactor(
            amountToMint,
            engine.getUsdValue(weth, amountCollateral)
        );

        console.log("uint256(price): ", uint256(price)); // 200,000,000,000
        console.log("amountToMint: ", amountToMint); // 20,000,000,000,000,000,000,000
        console.log("amountCollateral: ", amountCollateral); //     10,000,000,000,000,000,000 = 10 e18 (10 ether)
        console.log("expectedHealthFactor: ", expectedHealthFactor);

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine_HealthFactorIsBreakHealthFactor.selector,
                expectedHealthFactor
            )
        );

        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral); // amountCollateral = 10 ether
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral, // amountCollateral = 10 ether
            amountToMint // amountToMint = 100 ether
        );
        vm.stopPrank();
        _;
    }

    // This function mainly tests the minting of DSC
    // the numner of DSC minted should be transferred to the user balance
    function testCanMintWithDepositedCollateral()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 userBalance = dsc.balanceOf(USER);
        console.log("userBalance: ", userBalance); // 100 ether
        assertEq(userBalance, amountToMint);
    }

    function testCanRedeemCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral); // amountCollateral = 10 ether
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral, // amountCollateral = 10 ether
            amountToMint // amountToMint = 100 ether
        );

        uint256 startingBalance = ERC20Mock(weth).balanceOf(USER);
        console.log("startingBalance: ", startingBalance);

        //console.log("amountCollateral: ", amountCollateral); // 10 ether
        engine.redeemCollateral(weth, 1 ether); // amountCollateral = 10 ether

        uint256 endingBalance = ERC20Mock(weth).balanceOf(USER);
        vm.stopPrank();
        console.log("endingBalance: ", endingBalance); // 0
        assertEq(endingBalance, 1 ether);
    }

    function testRevertsIfRedeemAmountIsZero() public {
        // amountCollateral = 10 ether
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral, // amountCollateral = 10 ether
            amountToMint // amountToMint = 100 ether
        );

        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs()
        public
        depositeCollateral
    {
        // amountCollateral = 10 ether
        vm.expectEmit();
        emit CollateralRedeemed(USER, USER, weth, amountCollateral);
        vm.startPrank(USER);
        engine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero()
        public
        depositedCollateralAndMintedDsc
    {
        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreThanZero.selector);
        engine.redeemCollateralForDsc(weth, amountCollateral, 0);
    }

    // Expect the amount of DSC after call reedemCollateralForDsc
    function testDSCBurnAmountAfterRedeemCollateralForDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral); // allow engine to deposit collateral
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );

        // remember that to approve the engine to burn DSC
        dsc.approve(address(engine), amountToMint); // allow engine to burn DSC amountToMint

        uint256 startingBalance = dsc.balanceOf(USER);
        console.log("startingBalance: ", startingBalance); // 100 ether

        engine.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 endingBalance = dsc.balanceOf(USER);
        console.log("endingBalance: ", endingBalance); // 0 ether
        assertEq(endingBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 healthFactor = engine.calculateHealthFactor(
            amountToMint,
            engine.getUsdValue(weth, amountCollateral)
        );

        console.log("healthFactor: ", healthFactor);
        assertEq(healthFactor, engine.getHealthFactor(USER));
    }

    function testHealthFactorCalculation()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 healthFactor = engine.getHealthFactor(USER);
        console.log("healthFactor: ", healthFactor);
        assertEq(healthFactor, 100 ether); // 100 ether
    }

    function testHealthFactorBelowOne() public depositedCollateralAndMintedDsc {
        int256 price = 18e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(price);

        // so the collateral value in USD is 10 * 18 = $180
        // with threshold is 50% then the value is 90 / 100 = 0.9

        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(healthFactor, 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    function testHealthFactorIsNotRequiredToImprove() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );

        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorOk.selector);

        engine.liquidate(weth, USER, amountCollateral);
        vm.stopPrank();
    }

    function testMustImproveHealthFactorOnLiquidation() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );

        int256 price = 18e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(price);

        uint256 healthFactor = engine.getHealthFactor(USER);
        console.log("healthFactor: ", healthFactor);
        assertEq(healthFactor, 0.9 ether);

        dsc.approve(address(engine), amountToMint); // allow engine to burn DSC amountToMint
        engine.liquidate(weth, USER, amountToMint);

        healthFactor = engine.getHealthFactor(USER);
        console.log("New healthFactor: ", healthFactor);
        assert(healthFactor > 1 ether);
        vm.stopPrank();
    }
}
