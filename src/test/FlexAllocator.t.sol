// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {FlexLenderStrategy as FlexAllocatorStrategy} from "@flex/allocator/Strategy.sol";
import {LenderFactory} from "@flex/lender/LenderFactory.sol";
import {ICatFactory} from "@flex-script/interfaces/ICatFactory.sol";
import {ISortedTroves} from "@flex-test/interfaces/ISortedTroves.sol";
import {ITroveManager} from "@flex-test/interfaces/ITroveManager.sol";
import {Test} from "forge-std/Test.sol";

import {IFlexRouter} from "../interfaces/IFlexRouter.sol";
import {ShellDeployer} from "./utils/ShellDeployer.sol";

interface IAllowedStrategy {
    function setAllowed(address _depositor, bool _allowed) external;
}

contract FlexAllocatorTest is Test, ShellDeployer {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant YV_WETH_2 = 0xAc37729B76db6438CE62042AE1270ee574CA7571;
    address internal constant SUSDS_STRATEGY = 0x7130570BCEfCedBe9d15B5b11A33006156460f8f;

    string internal constant YEARN_ROOT = "lib/tokenized-strategy-periphery/lib/yearn-vaults-v3";
    string internal constant FLEX_ROOT = "../flex-contracts";
    string internal constant DEFAULT_YEARN_VYPER = "/tmp/vyper037/bin/vyper";
    string internal constant DEFAULT_FLEX_VYPER = "vyper";

    uint256 internal constant FORK_BLOCK = 24_541_660;

    IERC20 internal usdc = IERC20(USDC);
    IERC20 internal collateralToken = IERC20(YV_WETH_2);
    ITokenizedStrategy internal susdsStrategy = ITokenizedStrategy(SUSDS_STRATEGY);

    IVaultFactory internal vaultFactory;
    IVault internal vault;
    IFlexRouter internal router;
    FlexAllocatorStrategy internal intermediaryStrategy;
    ICatFactory internal catFactory;
    ITroveManager internal troveManager;
    ISortedTroves internal sortedTroves;
    address internal lender;

    address internal vaultManager = address(0xBEEF);
    address internal lenderKeeper = address(0xCAFE);
    address internal borrower = address(0xB0B0);
    address internal attacker = address(0xBAD);
    address internal feeRecipient = address(0xFEE);

    uint256 internal minimumDebt = 500;
    uint256 internal safeCollateralRatio = 115;
    uint256 internal minimumCollateralRatio = 110;
    uint256 internal maxPenaltyCollateralRatio = 105;
    uint256 internal minLiquidationFee = 50;
    uint256 internal maxLiquidationFee = 500;
    uint256 internal upfrontInterestPeriod = 7 days;
    uint256 internal interestRateAdjCooldown = 7 days;
    uint256 internal minimumPriceBufferPercentage = 1e18 - 5e16;
    uint256 internal startingPriceBufferPercentage = 1e18 + 1e16;
    uint256 internal reKickStartingPriceBufferPercentage = 1e18 + 10e16;
    uint256 internal stepDuration = 20;
    uint256 internal stepDecayRate = 20;
    uint256 internal auctionLength = 1 days;

    uint256 internal depositAmount = 200_000e6;
    uint256 internal borrowAmount = 25_000e6;
    uint256 internal borrowMoreAmount = 5_000e6;
    uint256 internal repayAmount = 5_000e6;
    uint256 internal collateralAmount = 100e18;
    uint256 internal marketCap = 100_000e6;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        vm.label(vaultManager, "vaultManager");
        vm.label(lenderKeeper, "lenderKeeper");
        vm.label(borrower, "borrower");
        vm.label(attacker, "attacker");
        vm.label(USDC, "USDC");
        vm.label(YV_WETH_2, "yvWETH-2");
        vm.label(SUSDS_STRATEGY, "sUSDS strategy");

        _deployVaultStack();
        _deployFlexMarket();
        _deployBridgeAndRouter();
    }

    function test_depositAutoAllocatesIntoSusdsStrategy() public {
        _depositIntoVault(address(this), depositAmount);

        uint256 currentDebt = vault.strategies(SUSDS_STRATEGY).current_debt;
        assertEq(currentDebt, depositAmount, "base debt");
        assertEq(vault.totalIdle(), 0, "vault idle");
    }

    function test_canReportLiveSusdsStrategy() public {
        _depositIntoVault(address(this), depositAmount);

        skip(3 days);

        address reporter = susdsStrategy.keeper();
        if (reporter == address(0)) {
            reporter = susdsStrategy.management();
        }

        vm.prank(reporter);
        susdsStrategy.report();
    }

    function test_routerBorrowMovesDebtFromSusdsToFlexLender() public {
        _depositIntoVault(address(this), depositAmount);
        _setRoute(_defaultAnnualRate());

        _fundBorrower();
        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);

        uint256 troveId = _openTrove(borrowAmount);
        ITroveManager.Trove memory trove = troveManager.troves(troveId);

        uint256 baseDebt = vault.strategies(SUSDS_STRATEGY).current_debt;
        uint256 intermediaryDebt = vault.strategies(address(intermediaryStrategy)).current_debt;

        assertEq(baseDebt, depositAmount - borrowAmount, "base debt");
        assertEq(intermediaryDebt, borrowAmount, "intermediary debt");
        assertEq(trove.owner, borrower, "borrower owner");
        assertEq(usdc.balanceOf(borrower) - borrowerUsdcBefore, borrowAmount, "borrower usdc delta");
    }

    function test_routerBorrowUsesExistingLenderIdleBeforeFunding() public {
        _depositIntoVault(address(this), depositAmount);
        _setRoute(_defaultAnnualRate());

        uint256 lenderIdle = 7_000e6;

        vm.startPrank(vaultManager);
        vault.update_debt(SUSDS_STRATEGY, depositAmount - lenderIdle);
        vault.update_debt(address(intermediaryStrategy), lenderIdle);
        vm.stopPrank();

        assertEq(usdc.balanceOf(lender), lenderIdle, "prefunded lender idle");

        _fundBorrower();
        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);

        _openTrove(borrowAmount);

        assertEq(vault.strategies(SUSDS_STRATEGY).current_debt, depositAmount - borrowAmount, "base debt");
        assertEq(vault.strategies(address(intermediaryStrategy)).current_debt, borrowAmount, "intermediary debt");
        assertEq(usdc.balanceOf(lender), 0, "lender idle spent");
        assertEq(usdc.balanceOf(borrower) - borrowerUsdcBefore, borrowAmount, "borrower usdc delta");
    }

    function test_routerRejectsDisabledOrLowRate() public {
        _depositIntoVault(address(this), depositAmount);
        _fundBorrower();
        uint256 annualRate = _defaultAnnualRate();

        vm.startPrank(borrower);
        collateralToken.approve(address(router), collateralAmount);

        vm.expectRevert(bytes("!route_disabled"));
        router.open_trove(
            address(vault), address(troveManager), collateralAmount, borrowAmount, 0, 0, annualRate, type(uint256).max
        );
        vm.stopPrank();

        _setRoute(annualRate + 1);

        vm.startPrank(borrower);
        collateralToken.approve(address(router), collateralAmount);

        vm.expectRevert(bytes("!min_rate"));
        router.open_trove(
            address(vault), address(troveManager), collateralAmount, borrowAmount, 0, 0, annualRate, type(uint256).max
        );
        vm.stopPrank();
    }

    function test_routerBorrowRepayAndClose() public {
        _depositIntoVault(address(this), depositAmount);
        _setRoute(_defaultAnnualRate());
        _fundBorrower();

        uint256 troveId = _openTrove(borrowAmount);

        vm.prank(borrower);
        troveManager.approve(address(router), true);

        vm.prank(borrower);
        router.borrow(address(vault), address(troveManager), troveId, borrowMoreAmount, type(uint256).max);

        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, borrower, "borrow owner");
        assertTrue(troveManager.approved(borrower, address(router)), "router approved");

        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);
        skip(1);
        vm.prank(borrower);
        router.repay(address(vault), address(troveManager), troveId, repayAmount);

        uint256 postRepayBaseDebt = vault.strategies(SUSDS_STRATEGY).current_debt;
        uint256 postRepayIntermediaryDebt = vault.strategies(address(intermediaryStrategy)).current_debt;

        assertEq(
            postRepayBaseDebt, depositAmount - borrowAmount - borrowMoreAmount + repayAmount, "base debt after repay"
        );
        assertEq(
            postRepayIntermediaryDebt, borrowAmount + borrowMoreAmount - repayAmount, "intermediary debt after repay"
        );

        uint256 borrowerCollateralBefore = collateralToken.balanceOf(borrower);

        skip(1);
        vm.prank(borrower);
        router.close(address(vault), address(troveManager), troveId);

        uint256 finalBaseDebt = vault.strategies(SUSDS_STRATEGY).current_debt;
        uint256 finalIntermediaryDebt = vault.strategies(address(intermediaryStrategy)).current_debt;
        ITroveManager.Trove memory closedTrove = troveManager.troves(troveId);

        assertEq(finalBaseDebt, depositAmount, "base debt after close");
        assertEq(finalIntermediaryDebt, 0, "intermediary debt after close");
        assertEq(uint8(closedTrove.status), uint8(ITroveManager.Status.closed), "closed status");
        assertGt(collateralToken.balanceOf(borrower), borrowerCollateralBefore, "borrower got collateral back");
    }

    function test_routerRejectsNonOwnerOnBorrowRepayAndClose() public {
        _depositIntoVault(address(this), depositAmount);
        _setRoute(_defaultAnnualRate());
        _fundBorrower();

        uint256 troveId = _openTrove(borrowAmount);

        vm.prank(borrower);
        troveManager.approve(address(router), true);

        vm.expectRevert(bytes("!trove_owner"));
        vm.prank(attacker);
        router.borrow(address(vault), address(troveManager), troveId, borrowMoreAmount, type(uint256).max);

        deal(USDC, attacker, depositAmount);

        vm.startPrank(attacker);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("!trove_owner"));
        router.repay(address(vault), address(troveManager), troveId, repayAmount);

        vm.expectRevert(bytes("!trove_owner"));
        router.close(address(vault), address(troveManager), troveId);
        vm.stopPrank();

        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, borrower, "owner unchanged");
        assertTrue(troveManager.approved(borrower, address(router)), "approval unchanged");
    }

    function test_routerRejectsUnapprovedBorrowerOnBorrowRepayAndClose() public {
        _depositIntoVault(address(this), depositAmount);
        _setRoute(_defaultAnnualRate());
        _fundBorrower();

        uint256 troveId = _openTrove(borrowAmount);

        vm.expectRevert(bytes("!router_approved"));
        vm.prank(borrower);
        router.borrow(address(vault), address(troveManager), troveId, borrowMoreAmount, type(uint256).max);

        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);

        skip(1);
        vm.expectRevert(bytes("!router_approved"));
        vm.prank(borrower);
        router.repay(address(vault), address(troveManager), troveId, repayAmount);

        skip(1);
        vm.expectRevert(bytes("!router_approved"));
        vm.prank(borrower);
        router.close(address(vault), address(troveManager), troveId);
    }

    function test_routerRepayDrainsIdleLenderFunds() public {
        _depositIntoVault(address(this), depositAmount);
        _setRoute(_defaultAnnualRate());
        _fundBorrower();

        uint256 troveId = _openTrove(borrowAmount);

        vm.prank(borrower);
        troveManager.approve(address(router), true);

        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);
        skip(1);
        vm.prank(borrower);
        router.repay(address(vault), address(troveManager), troveId, repayAmount);

        uint256 idle = usdc.balanceOf(lender);
        assertEq(idle, 0, "router drained idle");

        assertEq(
            _strategyCurrentDebt(address(intermediaryStrategy)),
            borrowAmount - repayAmount,
            "intermediary debt after idle drain"
        );
    }

    function test_routerOpenTroveUsesPerManagerOwnerIndexes() public {
        _depositIntoVault(address(this), depositAmount);
        _setRoute(_defaultAnnualRate());
        deal(USDC, borrower, 200_000e6);
        deal(YV_WETH_2, borrower, collateralAmount * 2);

        assertEq(router.owner_indexes(address(troveManager)), 0, "initial owner index");

        uint256 firstTroveId = _openTrove(borrowAmount);
        assertEq(router.owner_indexes(address(troveManager)), 1, "first owner index");

        uint256 secondTroveId = _openTrove(borrowAmount);
        assertEq(router.owner_indexes(address(troveManager)), 2, "second owner index");

        assertNotEq(firstTroveId, secondTroveId, "trove ids");
        assertEq(troveManager.troves(firstTroveId).owner, borrower, "first owner");
        assertEq(troveManager.troves(secondTroveId).owner, borrower, "second owner");
    }

    function _deployVaultStack() internal {
        address vaultOriginal = deployWithShell(_yearnVyper("contracts/VaultV3.vy"));

        vaultFactory = IVaultFactory(
            deployWithShell(
                _yearnVyper("contracts/VaultFactory.vy"), abi.encode("Flex Vault Factory", vaultOriginal, vaultManager)
            )
        );

        vault = IVault(vaultFactory.deploy_new_vault(USDC, "Yearn Flex Router", "yvFlexRouter", vaultManager, 7 days));

        vm.startPrank(vaultManager);
        vault.set_role(vaultManager, Roles.ALL);
        vault.set_deposit_limit(type(uint256).max);
        vault.set_use_default_queue(true);
        vault.set_auto_allocate(true);
        vault.set_minimum_total_idle(0);
        vault.add_strategy(SUSDS_STRATEGY);
        vault.update_max_debt_for_strategy(SUSDS_STRATEGY, type(uint256).max);
        vm.stopPrank();

        vm.prank(susdsStrategy.management());
        IAllowedStrategy(SUSDS_STRATEGY).setAllowed(address(vault), true);
    }

    function _deployFlexMarket() internal {
        address originalAuction = deployWithShell(_flexVyper("src/auction.vy"));
        address originalDutchDesk = deployWithShell(_flexVyper("src/dutch_desk.vy"));
        address originalSortedTroves = deployWithShell(_flexVyper("src/sorted_troves.vy"));
        address originalTroveManager = deployWithShell(_flexVyper("src/trove_manager.vy"));
        address priceOracle = deployWithShell(_flexVyper("src/oracles/yvweth2_to_usdc_oracle.vy"));

        LenderFactory lenderFactory = new LenderFactory(vaultManager);
        catFactory = ICatFactory(
            deployWithShell(
                _flexVyper("src/factory.vy"),
                abi.encode(
                    originalTroveManager,
                    originalSortedTroves,
                    originalDutchDesk,
                    originalAuction,
                    address(lenderFactory)
                )
            )
        );

        (address troveManager_, address sortedTroves_,,, address lender_) = catFactory.deploy(
            ICatFactory.DeployParams({
                borrow_token: USDC,
                collateral_token: YV_WETH_2,
                price_oracle: priceOracle,
                minimum_debt: minimumDebt,
                safe_collateral_ratio: safeCollateralRatio,
                minimum_collateral_ratio: minimumCollateralRatio,
                max_penalty_collateral_ratio: maxPenaltyCollateralRatio,
                min_liquidation_fee: minLiquidationFee,
                max_liquidation_fee: maxLiquidationFee,
                upfront_interest_period: upfrontInterestPeriod,
                interest_rate_adj_cooldown: interestRateAdjCooldown,
                minimum_price_buffer_percentage: minimumPriceBufferPercentage,
                starting_price_buffer_percentage: startingPriceBufferPercentage,
                re_kick_starting_price_buffer_percentage: reKickStartingPriceBufferPercentage,
                step_duration: stepDuration,
                step_decay_rate: stepDecayRate,
                auction_length: auctionLength,
                salt: bytes32(uint256(420_420))
            })
        );

        troveManager = ITroveManager(troveManager_);
        sortedTroves = ISortedTroves(sortedTroves_);
        lender = lender_;
    }

    function _deployBridgeAndRouter() internal {
        intermediaryStrategy = new FlexAllocatorStrategy(USDC, lender, "Flex Lender Bridge");

        ITokenizedStrategy(address(intermediaryStrategy)).setPendingManagement(vaultManager);
        vm.prank(vaultManager);
        ITokenizedStrategy(address(intermediaryStrategy)).acceptManagement();
        vm.prank(vaultManager);
        ITokenizedStrategy(address(intermediaryStrategy)).setKeeper(lenderKeeper);
        vm.prank(vaultManager);
        intermediaryStrategy.setAllowed(address(vault), true);

        vm.startPrank(vaultManager);
        vault.add_strategy(address(intermediaryStrategy));
        vault.update_max_debt_for_strategy(address(intermediaryStrategy), marketCap);
        vm.stopPrank();

        router = IFlexRouter(deployCode("FlexRouter.vy"));

        vm.prank(vaultManager);
        vault.set_role(address(router), Roles.DEBT_MANAGER);
    }

    function _depositIntoVault(address depositor, uint256 amount) internal {
        deal(USDC, depositor, amount);

        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, depositor);
        vm.stopPrank();
    }

    function _fundBorrower() internal {
        deal(USDC, borrower, 200_000e6);
        deal(YV_WETH_2, borrower, collateralAmount);
    }

    function _setRoute(uint256 minRate) internal {
        vm.prank(vaultManager);
        router.set_route(address(vault), address(troveManager), address(intermediaryStrategy), minRate);
    }

    function _defaultAnnualRate() internal view returns (uint256) {
        return troveManager.min_annual_interest_rate() * 2;
    }

    function _openTrove(uint256 amount) internal returns (uint256 troveId) {
        vm.startPrank(borrower);
        collateralToken.approve(address(router), collateralAmount);
        troveId = router.open_trove(
            address(vault),
            address(troveManager),
            collateralAmount,
            amount,
            0,
            0,
            _defaultAnnualRate(),
            type(uint256).max
        );
        vm.stopPrank();
    }

    function _strategyCurrentDebt(address strategy) internal view returns (uint256 currentDebt) {
        currentDebt = vault.strategies(strategy).current_debt;
    }

    function _yearnVyper(string memory relativePath) internal view returns (string memory) {
        return string.concat("cd ", YEARN_ROOT, " && ", vm.envOr("YEARN_VYPER", DEFAULT_YEARN_VYPER), " ", relativePath);
    }

    function _flexVyper(string memory relativePath) internal view returns (string memory) {
        return string.concat(
            "cd ",
            FLEX_ROOT,
            " && ",
            vm.envOr("FLEX_VYPER", DEFAULT_FLEX_VYPER),
            " --evm-version paris -p src -p lib/snekmate/src ",
            relativePath
        );
    }
}
