// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

//import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

// The IERC20.sol file defines the interface for the ERC20 token standard, which includes the required and
// optional functions that an ERC20 token must implement. The OpenZeppelin ERC20 contract implements this interface,
// which allows it to be recognized as an ERC20 token by other contracts and applications.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Test, console} from "forge-std/Test.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

// AggregatorV3Interface is an oracle - so we need to make sure that if AggregatorV3Interface is not working then we need to
// our protocol should be able to handle that

/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * Our DSC sytem should always be "overcollateralized". At no point, shoudl the value of all
 * collateral <= the $ back value of all the DSC
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS (DAI) system
 */

contract DSCEngine is ReentrancyGuard {
    /**
     * ERRORS
     */
    error DSCEngine_NeedMoreThanZero();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_TokenAndPriceAddressesShouldHaveSameLength();
    error DSCEngine_TransferFailed();
    error DSCEngine_HealthFactorIsBreakHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorOk();
    error DSCEngine_HealthFactorNotImproved();

    /***********
     *** TYPES ***
     ***********/
    using OracleLib for AggregatorV3Interface;

    /**
     * STATE VARIABLE
     */
    // a list of allowed tokens
    mapping(address token => address priceFeed) s_priceFeeds; // this state variables will be set in contractor
    // Why we need to have price feed? -> because we need to know how much the Eth value that customer have?
    // That why we need get the price feed of pair ETH/USD
    //address[] whitelistAddreses = [address(0)];

    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;

    // This keep the number of DSC stable coin hold by each user
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    // Because we can't loop through the map that why we need to
    // create a separate list to store collateral tokens
    address[] private s_collateralTokens;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    DecentralizedStableCoin private immutable i_dsc;

    /**
     * EVENTS
     */
    event CollateralDeposited(
        address indexed sender,
        address indexed tokenCollateralAddress,
        uint256 indexed amountCollateral
    );

    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address token,
        uint256 amount
    );

    /**
     * MODIFIERS
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_NeedMoreThanZero();
        }
        _;
    }

    // create a new modifier that allow a certain of address token
    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    /**
     * FUNCTIONS
     */
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAndPriceAddressesShouldHaveSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        // This function will call the Ownable function
        // constructor(address initialOwner) {
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * External FUNCTIONS
     */
    // This function will put collateral and create new stable coin
    function depositCollateralAndMintDsc(
        address tokenCollateral,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) public {
        depositCollateral(tokenCollateral, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     *
     * @param tokenCollateralAddress - the adress of the token to deposit collteral
     * @param amountCollateral - the amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant // This assure that reentrant attack when working with web3 - https://solidity-by-example.org/hacks/re-entrancy/
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );

        // Why using address(this) ???
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );

        _printOutTheCollateralDeposited(msg.sender);

        /* IERC20(tokenCollateralAddress) -> is expected to be an ERC-20 token, and the contract is interacting with it. 
          transferFrom is a function defined in the ERC-20 standard that allows one address (in this case, msg.sender) 
          to transfer a certain amount of tokens from that address to another address (address(this) in this case).
          The use of address(this) as the recipient suggests that the deposited collateral is being transferred to the contract itself.
        */
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    /**
     * In order to allow redeem collater:
     * 1. The health factor must be over than 1 AFTER collteral pulled out
     *
     */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateralRedeem
    )
        public
        moreThanZero(amountCollateralRedeem)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateralRedeem,
            msg.sender,
            msg.sender
        );

        // Make sure health factor is not broken
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // Check if the collateral value >= minimum threshold
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;

        // If they mint too much the we need to revert
        // for example $150 DSC, and have only $100 ETH
        _revertIfHealthFactorIsBroken(msg.sender);

        // Mint DSC
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    // This function will exchange stablecoin back to collateral (BTC/ETH)
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) public moreThanZero(amountDscToBurn) {
        // burn dsc first

        burnDsc(amountDscToBurn);
        // the get back collateral
        // need to convert DSC to collateral?
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // For the case they worried that there are too much stabe coin then they want to reduce
    // the number of coins
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        // There is a need to check whether the amount is bigger than avaialbe amount?
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // To handle the case when collateral value drop to much
    // For example
    // Collateral: $100 ETH -> $40 ETH
    // and $50 DSC
    // we have more collateral than DSC
    // TO avoid the case where collateral < DSC
    // We need to set some threshold like 20%
    //   if you have $60 = $50 + $10 ($50*20%) then you should get kicked out of the system
    //   because you are way to close to being under collaterized

    // so the liquidate function being called to remove people's position to save protocol
    // so we can set a threshold that for example 150%
    // so with $50 DSC the threshold will be $75

    /**
    // 200% overcollateralized?
    ---> Make sure balance like this $100 backing for $50 DSC



    // You will get a liquidation bonus for taking the users fund.??
    -----> we want to incentivize them to do this
        For example $50 backing for $50 DSC -> customer get back %50 for burn $50 DSC -> Customer not happy to doing that
        What if we pay $75 instead as a bonus for them
        
     */

    /**
     * @param user - user who has broken healfactor where _healFactor is below MIN_HEALTH_FACTOR
     * @param debtToCover - the amount of DSC to burn to improve the health factor
     *
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users fund.
     *
     * @notice This function working assumes that the protocal were 200% ovecollateralized to make it work
     * @notice A known bug would be if the protocol were 100% or less collateralized then we wouldn't be able incentive the
     *      liquidator.
     *  For example if the price of the collateral plummeted before anyone could be liquited
     *
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) public moreThanZero(debtToCover) nonReentrant {
        // check the healfactor
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }
        // If covering 100 DSC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(
            collateral,
            tokenAmountFromDebtCovered + bonusCollateral,
            user,
            msg.sender
        );
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // see how healthy people are
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * PRIVATE AND INTERNAL View Functions
     */

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        //console.log("from: ", from);
        //console.log("tokenCollateralAddress: ", tokenCollateralAddress);

        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        _printOutTheCollateralDeposited(from);

        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );

        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );

        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _printOutTheCollateralDeposited(address user) private view {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            console.log(
                "s_collateralDeposited[user][s_collateralTokens[i]]: ",
                s_collateralDeposited[user][s_collateralTokens[i]]
            );
        }
    }

    function _burnDsc(
        uint256 amount,
        address onBehalfOf,
        address dscFromAddress
    ) private {
        s_dscMinted[onBehalfOf] -= amount;

        console.log(
            "i_dsc.balanceOf(dscFromAddress): ",
            i_dsc.balanceOf(dscFromAddress)
        );
        bool success = i_dsc.transferFrom(
            dscFromAddress,
            address(this),
            amount
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amount);
    }

    function _getAccountInformation(
        address user
    ) private view returns (uint256, uint256) {
        uint256 totalDscMinted = s_dscMinted[user];
        uint256 collateralValueInUsd = getCollateralValueInUsd(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        // Debug information here
        console.log("totalDscMinted: ", totalDscMinted); // 19 000
        console.log("collateralValueInUsd: ", collateralValueInUsd); // 20,000 e18

        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check health factor - do they have enough collateral?
        // 2. revert if so
        uint256 healthFactor = _healthFactor(user);
        console.log("healthFactor: ", healthFactor);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorIsBreakHealthFactor(healthFactor);
        }
    }

    /**
     * PUBLIC & External View Functions
     */
    function getCollateralValueInUsd(
        address user
    ) public view returns (uint256) {
        // Loop through each collateral token and get the amount that they have deposited and
        // map it to the price and get the USD value
        uint256 totalValue = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 tokenAmount = s_collateralDeposited[user][token];
            totalValue += getUsdValue(token, tokenAmount);
        }

        return totalValue;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );

        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000
        // the return from chainlink will be 1000 * 1e8
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromDscUsd(
        address tokenCollateralAddress,
        uint256 debtToCover
    ) public moreThanZero(debtToCover) nonReentrant returns (uint256) {
        // price of ETH
        // let say price of ETH is $2000 and the dscUsdAmount is $1000
        // so the amount of ETH is 0.5
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[tokenCollateralAddress]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        // 10e36 / 2000e18
        // debtToCover = $100 of DSC
        // 0.05 ETH
        return
            (debtToCover * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getTotalCollateralForTokenAndUser(
        address user,
        address token
    ) external view returns (uint256 totalCollateralForTokenAndUser) {
        return s_collateralDeposited[user][token];
    }

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getTokenAddresses() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(
        address _collateralToken
    ) external view returns (address) {
        return s_priceFeeds[_collateralToken];
    }
}
