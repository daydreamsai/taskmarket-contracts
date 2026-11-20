// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskCreationFee } from "../src/hooks/sponsored-task/SponsoredTaskCreationFee.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskSettler } from "../src/hooks/sponsored-task/SponsoredTaskSettler.sol";
import { DeploySponsoredTaskSettler, RedeploySponsoredTaskSettler } from "../script/DeploySponsoredTaskSettler.s.sol";
import { RedeploySponsoredTaskFactoryV2 } from "../script/DeployHooksV2.s.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

contract SettlerAdminStandIn { }

/// @dev Answers like a settler deployed before rev031, whose `Reserve` has no deadline.
contract UnboundedReserveSettlerStandIn {
    bytes32 public constant RESERVE_TYPEHASH = keccak256(
        "Reserve(address vault,bytes32 vaultId,bytes32 allocationId,uint256 taskChainId,bytes32 taskId,uint64 commitmentNonce,address manager,uint256 grossAmount,uint64 epoch,uint16 feeBps,address feeRecipient,bytes32 termsHash)"
    );
}

contract SponsoredTaskSettlerDeployScriptsTest is Test {
    uint256 private constant DEPLOYER_KEY = 0xA11CE;
    address private admin;
    MockERC20 private usdc;

    function setUp() public {
        admin = address(new SettlerAdminStandIn());
        usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        vm.setEnv("FORGE_USDC_TOKEN_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("FORGE_SPONSORED_TASK_CREATION_FEE_USDC", "1000000");
        vm.setEnv("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT", vm.toString(address(0xFEE)));
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_ADMIN", vm.toString(admin));
        vm.setEnv("FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN", vm.toString(admin));
        vm.setEnv("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", "750");
        vm.setEnv("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT", vm.toString(address(0xFEE)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(0xD1A)));
        vm.etch(address(0xD1A), hex"00"); // the remote hook script refuses a diamond without code
    }

    function test_DeploySettler_AdminOwnsSettlerAndFactoryIsControlledBySettler() public {
        vm.setEnv(
            "FORGE_SPONSORED_TASK_SETTLER_ADDRESSES",
            string.concat(
                vm.toString(address(0xBBB)), ",", vm.toString(address(0xAAA)), ",", vm.toString(address(0xCCC))
            )
        );
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_THRESHOLD", "2");
        vm.recordLogs();
        new DeploySponsoredTaskSettler().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        SponsoredTaskSettler settler;
        SponsoredTaskFactoryV2 factory;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SponsoredTaskSettler.SettlersChanged.selector) {
                settler = SponsoredTaskSettler(logs[i].emitter);
            }
            if (logs[i].topics[0] == SponsoredTaskRegistry.FactoryAuthorizationUpdated.selector) {
                factory = SponsoredTaskFactoryV2(address(uint160(uint256(logs[i].topics[1]))));
            }
        }
        assertEq(settler.owner(), admin);
        assertEq(settler.threshold(), 2);
        address[] memory list = settler.settlers();
        assertEq(list.length, 3);
        assertEq(list[0], address(0xAAA));
        assertEq(list[2], address(0xCCC));
        assertEq(factory.controller(), address(settler));
        assertEq(SponsoredTaskRegistry(address(factory.registry())).pendingOwner(), admin);
        assertEq(address(factory.feeToken()), address(usdc));
        assertEq(factory.creationFee(), 1_000_000);
        assertEq(factory.creationFeeRecipient(), address(0xFEE));
    }

    function test_DeploySettler_RejectsDeployerAsAdmin() public {
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_ADDRESSES", vm.toString(address(0xAAA)));
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_THRESHOLD", "1");
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_ADMIN", vm.toString(vm.addr(DEPLOYER_KEY)));
        DeploySponsoredTaskSettler script = new DeploySponsoredTaskSettler();
        vm.expectRevert(bytes("Settler: admin must be a contract"));
        script.run();
    }

    /// @dev A live settler-mode pair, built directly so no per-test env value is shared between
    ///      tests running at once. The registry is still the deployer key's, as right after
    ///      `DeploySponsoredTaskSettler` and before the admin accepts it.
    function _deployPair() private returns (SponsoredTaskSettler settler, SponsoredTaskFactoryV2 factory) {
        address[] memory settlers = new address[](2);
        settlers[0] = address(0xAAA);
        settlers[1] = address(0xBBB);
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(vm.addr(DEPLOYER_KEY));
        settler = new SponsoredTaskSettler(admin, settlers, 2, registry);
        factory = new SponsoredTaskFactoryV2(
            address(settler),
            address(new SettlerAdminStandIn()),
            registry,
            SponsoredTaskCreationFee.CreationFeeConfig({ token: usdc, amount: 1_000_000, recipient: address(0xFEE) })
        );
        vm.prank(vm.addr(DEPLOYER_KEY));
        registry.setFactory(address(factory), true);
    }

    function _createVault(SponsoredTaskFactoryV2 factory, bytes32 salt) private returns (address vault) {
        usdc.mint(address(this), factory.creationFee());
        usdc.approve(address(factory), factory.creationFee());
        (vault,) = factory.createVault(address(usdc), address(this), salt);
    }

    /// @dev Rev031: the new settler copies the live one's owner, settler set, threshold and registry;
    ///      the new factory is controlled by it; the old factory is deauthorized and its vaults stay
    ///      registered and controlled by the old settler.
    function test_RedeploySettler_ReplacesThePairAndKeepsOldVaults() public {
        (SponsoredTaskSettler previousSettler, SponsoredTaskFactoryV2 previous) = _deployPair();
        address oldVault = _createVault(previous, keccak256("old"));

        (SponsoredTaskSettler settler, SponsoredTaskFactoryV2 factory) =
            new RedeploySponsoredTaskSettler().redeploy(previous);

        assertTrue(address(settler) != address(previousSettler), "a new settler");
        assertEq(settler.owner(), previousSettler.owner(), "same owner");
        assertEq(settler.threshold(), 2, "same threshold");
        assertEq(settler.settlers(), previousSettler.settlers(), "same settler set");
        assertEq(address(settler.registry()), address(previousSettler.registry()), "same registry");
        assertEq(factory.controller(), address(settler), "new factory controlled by the new settler");
        assertEq(factory.feePolicy(), previous.feePolicy(), "same fee policy");
        assertEq(factory.creationFee(), previous.creationFee(), "same creation fee");
        assertEq(factory.creationFeeRecipient(), previous.creationFeeRecipient(), "same fee recipient");
        assertEq(address(factory.feeToken()), address(previous.feeToken()), "same fee token");

        SponsoredTaskRegistry registry = SponsoredTaskRegistry(address(factory.registry()));
        assertTrue(registry.authorizedFactories(address(factory)), "new factory authorized");
        assertFalse(registry.authorizedFactories(address(previous)), "old factory deauthorized");
        assertTrue(registry.isVault(oldVault), "old vault stays registered");
        address newVault = _createVault(factory, keccak256("new"));
        assertTrue(registry.isVault(newVault), "new vaults register");

        usdc.mint(address(this), previous.creationFee());
        usdc.approve(address(previous), previous.creationFee());
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskRegistry.UnauthorizedFactory.selector, address(previous)));
        previous.createVault(address(usdc), address(this), keccak256("late"));
    }

    function test_RedeploySettler_LeavesTheRegistryToItsOwner() public {
        (, SponsoredTaskFactoryV2 previous) = _deployPair();
        SponsoredTaskRegistry registry = SponsoredTaskRegistry(address(previous.registry()));
        vm.prank(vm.addr(DEPLOYER_KEY));
        registry.transferOwnership(admin);
        vm.prank(admin);
        registry.acceptOwnership();

        (, SponsoredTaskFactoryV2 factory) = new RedeploySponsoredTaskSettler().redeploy(previous);
        assertFalse(registry.authorizedFactories(address(factory)), "the owner authorizes the new factory");
        assertTrue(registry.authorizedFactories(address(previous)), "the owner deauthorizes the old one");
    }

    function test_RedeployFactory_RefusesASettlerWithAnUnboundedReserve() public {
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        SponsoredTaskFactoryV2 previous = new SponsoredTaskFactoryV2(
            address(new UnboundedReserveSettlerStandIn()),
            address(new SettlerAdminStandIn()),
            registry,
            SponsoredTaskCreationFee.CreationFeeConfig({ token: usdc, amount: 0, recipient: address(0xFEE) })
        );
        RedeploySponsoredTaskFactoryV2 script = new RedeploySponsoredTaskFactoryV2();
        vm.expectRevert(
            bytes("Sponsored Task factory: settler signs an older Reserve; use RedeploySponsoredTaskSettler")
        );
        script.redeploy(previous);
    }

    function test_RedeployFactory_AcceptsACurrentSettler() public {
        (SponsoredTaskSettler settler, SponsoredTaskFactoryV2 previous) = _deployPair();
        SponsoredTaskFactoryV2 factory = new RedeploySponsoredTaskFactoryV2().redeploy(previous);
        assertEq(factory.controller(), address(settler));
    }
}
