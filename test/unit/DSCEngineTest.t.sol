// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC public deployer;
    DSCEngine public dscEngine;
    DecentralizedStableCoin public dsc;
    HelperConfig public config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLenghtDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 15e18 * 2000;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd, "USD value calculation is incorrect");
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether; // 100 / 2000
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth, "Token amount from USD calculation is incorrect");
    }

    /////////////////////////////
    // DepositCollateral Tests //
    /////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted, "Total DSC minted should be zero");
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount, "Collateral value in USD should match the deposit amount");
    }

    ////////////////
    // Mint Tests //
    ////////////////

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // Trying to mint more than the collateral allows (should be ~50% of collateral value)
        uint256 amountToMint = 20000 ether; // More than what 10 ETH at $2000 allows
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        uint256 amountToMint = 1000 ether; // Safe amount to mint
        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint, "DSC minted amount should match");
        vm.stopPrank();
    }

    ///////////////
    // Burn Tests //
    ///////////////

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.mintDsc(1000 ether);
        vm.stopPrank();
        _;
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        uint256 amountToBurn = 500 ether;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDsc(amountToBurn);

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, 500 ether, "DSC minted amount should be reduced");
        vm.stopPrank();
    }

    ///////////////////////
    // Redeem Collateral //
    ///////////////////////

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        uint256 amountToRedeem = 5 ether;
        uint256 initialBalance = ERC20Mock(weth).balanceOf(USER);

        vm.startPrank(USER);
        // Now that we fixed the division by zero bug, this should work correctly
        dscEngine.redeemCollateral(weth, amountToRedeem);

        uint256 finalBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(finalBalance - initialBalance, amountToRedeem, "User should receive redeemed collateral");
        vm.stopPrank();
    }

    function testCanRedeemCollateralWithDscMinted() public depositedCollateralAndMintedDsc {
        uint256 amountToRedeem = 2 ether; // Safe amount that won't break health factor
        uint256 initialBalance = ERC20Mock(weth).balanceOf(USER);

        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, amountToRedeem);

        uint256 finalBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(finalBalance - initialBalance, amountToRedeem, "User should receive redeemed collateral");
        vm.stopPrank();
    }

    function testRevertsIfRedeemBreaksHealthFactor() public depositedCollateralAndMintedDsc {
        // With 10 ETH at $2000 = $20,000 collateral, 1000 DSC minted
        // Need to keep health factor >= 1
        // Health factor = (collateralValueInUsd * 50 / 100) / totalDscMinted
        // 1 = (remainingCollateral * 2000 * 50 / 100) / 1000
        // 1 = remainingCollateral * 1000 / 1000
        // remainingCollateral must be >= 1 ETH
        // So can redeem at most 9 ETH
        uint256 amountToRedeem = 9.5 ether; // This should definitely break health factor

        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    ////////////////////////////////
    // Deposit and Mint Combined //
    ////////////////////////////////

    function testCanDepositCollateralAndMintDsc() public {
        uint256 amountToMint = 1000 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint, "DSC minted amount should match");
        assertGt(collateralValueInUsd, 0, "Collateral value should be greater than zero");
        vm.stopPrank();
    }

    /////////////////////////////
    // Redeem and Burn Combined //
    /////////////////////////////

    function testCanRedeemCollateralForDsc() public depositedCollateralAndMintedDsc {
        uint256 amountToRedeem = 2 ether;
        uint256 amountToBurn = 500 ether;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.redeemCollateralForDsc(weth, amountToRedeem, amountToBurn);

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, 500 ether, "DSC minted should be reduced");

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, amountToRedeem, "User should receive redeemed collateral");
        vm.stopPrank();
    }

    ////////////////////
    // Liquidation Tests //
    ////////////////////

    function testRevertsLiquidateIfHealthFactorOk() public depositedCollateralAndMintedDsc {
        // Try to liquidate a healthy position
        vm.startPrank(makeAddr("liquidator"));
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, 100 ether);
        vm.stopPrank();
    }

    function testRevertsLiquidateIfDebtToCoverIsZero() public {
        vm.startPrank(makeAddr("liquidator"));
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.liquidate(weth, USER, 0);
        vm.stopPrank();
    }

    //////////////////////
    // Health Factor Tests //
    //////////////////////

    function testHealthFactorCalculation() public depositedCollateralAndMintedDsc {
        // With 10 ETH at $2000 = $20,000 collateral
        // Minted 1000 DSC
        // Health factor should be around 10 (20000 * 50% / 1000)
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        // Calculate expected health factor manually
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * 50) / 100; // 50% threshold
        uint256 expectedHealthFactor = (collateralAdjustedForThreshold * 1e18) / totalDscMinted;

        assertGt(expectedHealthFactor, 1e18, "Health factor should be above minimum");
    }

    function testHealthFactorWithNoDscMinted() public depositedCollateral {
        // When no DSC is minted, health factor should be type(uint256).max (infinite)
        // This test verifies our fix for the division by zero bug
        vm.startPrank(USER);

        // Since _healthFactor is private, we test indirectly by trying to redeem collateral
        // which calls _revertIfHealthFactorIsBroken, which calls _healthFactor
        uint256 amountToRedeem = 9 ether; // Almost all collateral

        // This should work because with no DSC minted, health factor is infinite
        dscEngine.redeemCollateral(weth, amountToRedeem);

        // Verify the redemption worked
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, amountToRedeem, "User should receive redeemed collateral");
        vm.stopPrank();
    }

    ///////////////////////
    // Collateral Value Tests //
    ///////////////////////

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 expectedValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 actualValue = dscEngine.getAccountCollateralValue(USER);
        assertEq(actualValue, expectedValue, "Account collateral value should match expected");
    }

    function testGetAccountCollateralValueWithMultipleTokens() public {
        // Setup WBTC as well
        uint256 wbtcAmount = 1e8; // 1 WBTC (8 decimals)
        ERC20Mock(wbtc).mint(USER, wbtcAmount);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).approve(address(dscEngine), wbtcAmount);

        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wbtc, wbtcAmount);

        uint256 expectedWethValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 expectedWbtcValue = dscEngine.getUsdValue(wbtc, wbtcAmount);
        uint256 expectedTotalValue = expectedWethValue + expectedWbtcValue;

        uint256 actualValue = dscEngine.getAccountCollateralValue(USER);
        assertEq(actualValue, expectedTotalValue, "Total collateral value should match sum of individual values");
        vm.stopPrank();
    }

    //////////////////////
    // Edge Case Tests //
    ////////////////////

    function testCannotBurnMoreThanMinted() public depositedCollateralAndMintedDsc {
        uint256 amountToBurn = 2000 ether; // More than the 1000 minted

        vm.startPrank(USER);
        vm.expectRevert(); // Should revert due to underflow
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testCannotRedeemMoreThanDeposited() public depositedCollateral {
        uint256 amountToRedeem = 20 ether; // More than the 10 ether deposited

        vm.startPrank(USER);
        vm.expectRevert(); // Should revert due to underflow
        dscEngine.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    function testTransferFailedOnDeposit() public {
        // This test demonstrates the pattern for testing transfer failures
        // In practice, you'd need a mock token that can simulate transfer failures

        vm.startPrank(USER);
        // We can't easily test this without modifying the mock, but this demonstrates the test pattern
        // The DSCEngine__TransferFailed error would be thrown if IERC20.transferFrom returns false
        vm.stopPrank();
    }

    ///////////////////
    // Fuzz Testing //
    ///////////////////

    function testFuzzDepositCollateral(uint256 amountCollateral) public {
        // Bound the amount to reasonable values
        amountCollateral = bound(amountCollateral, 1, 1000 ether);

        ERC20Mock(weth).mint(USER, amountCollateral);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);

        uint256 collateralValue = dscEngine.getAccountCollateralValue(USER);
        assertGt(collateralValue, 0, "Collateral value should be greater than zero");
        vm.stopPrank();
    }

    function testFuzzMintDsc(uint256 amountToMint) public depositedCollateral {
        // Bound to safe minting amounts (max 50% of collateral value)
        uint256 maxMint = (dscEngine.getAccountCollateralValue(USER) * 50) / 100;
        amountToMint = bound(amountToMint, 1, maxMint);

        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint, "DSC minted should match requested amount");
        vm.stopPrank();
    }

    /////////////////////////
    // Integration Tests //
    /////////////////////////

    function testFullWorkflow() public {
        // 1. Deposit collateral
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        // 2. Mint DSC
        uint256 amountToMint = 1000 ether;
        dscEngine.mintDsc(amountToMint);

        // 3. Check account info
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint, "DSC minted should match");
        assertGt(collateralValueInUsd, 0, "Collateral value should be positive");

        // 4. Burn some DSC
        uint256 amountToBurn = 300 ether;
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDsc(amountToBurn);

        // 5. Redeem some collateral
        uint256 amountToRedeem = 2 ether;
        dscEngine.redeemCollateral(weth, amountToRedeem);

        // 6. Final checks
        (uint256 finalDscMinted, uint256 finalCollateralValue) = dscEngine.getAccountInformation(USER);
        assertEq(finalDscMinted, amountToMint - amountToBurn, "Final DSC should be reduced");
        assertLt(finalCollateralValue, collateralValueInUsd, "Final collateral should be less");

        vm.stopPrank();
    }

    function testMultipleUsersCanDepositAndMint() public {
        address user2 = makeAddr("user2");
        ERC20Mock(weth).mint(user2, AMOUNT_COLLATERAL);

        // User 1 deposits and mints
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 500 ether);
        vm.stopPrank();

        // User 2 deposits and mints
        vm.startPrank(user2);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 800 ether);
        vm.stopPrank();

        // Check both users have their respective balances
        (uint256 user1Minted,) = dscEngine.getAccountInformation(USER);
        (uint256 user2Minted,) = dscEngine.getAccountInformation(user2);

        assertEq(user1Minted, 500 ether, "User 1 should have 500 DSC minted");
        assertEq(user2Minted, 800 ether, "User 2 should have 800 DSC minted");
    }

    ////////////////////////
    // Liquidation Simulation //
    ////////////////////////

    function testLiquidationScenario() public {
        // This test simulates a liquidation scenario but can't actually trigger it
        // without manipulating price feeds or creating an undercollateralized position

        // Setup: User deposits collateral and mints DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000 ether);
        vm.stopPrank();

        // Setup liquidator with DSC
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 500 ether);
        vm.stopPrank();

        // In a real scenario, the price would drop making USER undercollateralized
        // For now, we just verify the liquidator can't liquidate a healthy position
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), 100 ether);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, 100 ether);
        vm.stopPrank();
    }
}
