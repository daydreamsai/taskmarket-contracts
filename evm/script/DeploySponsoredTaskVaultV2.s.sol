// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskCreationFee } from "../src/hooks/sponsored-task/SponsoredTaskCreationFee.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";

/// @notice Deploys `SponsoredTaskFactoryV2` beside an existing Sponsored Task stack.
/// @dev The v2 factory takes its controller (the hook), fee policy and registry from the deployed
///      v1 factory, so both factories create vaults for the same hook under the same fee terms.
///      It takes the one-time vault creation fee from each vault creator. The registry must
///      authorize the new factory before it can create a vault; when the deployer does not own the
///      registry (normally the admin Safe does), the script prints the call for the owner to
///      execute instead.
///
///      Env: FORGE_DEV_PRIVATE_KEY, FORGE_SPONSORED_TASK_FACTORY_ADDRESS (the v1 factory),
///      FORGE_SPONSORED_TASK_ADMIN (a Safe or timelock that owns the creation fee),
///      FORGE_USDC_TOKEN_ADDRESS, FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT,
///      FORGE_SPONSORED_TASK_FEE_CEILING_USDC and optionally FORGE_SPONSORED_TASK_CREATION_FEE_USDC
///      (default 1_000_000 = $1).
contract DeploySponsoredTaskVaultV2 is Script {
    function run() external returns (SponsoredTaskFactoryV2 factoryV2) {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        SponsoredTaskFactory factoryV1 = SponsoredTaskFactory(vm.envAddress("FORGE_SPONSORED_TASK_FACTORY_ADDRESS"));
        address admin = vm.envAddress("FORGE_SPONSORED_TASK_ADMIN");
        require(address(factoryV1).code.length != 0, "Sponsored Task vault v2: missing v1 factory code");
        require(admin.code.length != 0, "Sponsored Task vault v2: admin must be a contract");
        uint256 creationFee = vm.envOr("FORGE_SPONSORED_TASK_CREATION_FEE_USDC", uint256(1_000_000));

        SponsoredTaskRegistry registry = SponsoredTaskRegistry(address(factoryV1.registry()));
        address controller = factoryV1.controller();
        address feePolicy = factoryV1.feePolicy();

        vm.startBroadcast(deployerKey);
        factoryV2 = new SponsoredTaskFactoryV2(
            controller,
            feePolicy,
            registry,
            SponsoredTaskCreationFee.CreationFeeConfig({
                admin: admin,
                token: IERC20(vm.envAddress("FORGE_USDC_TOKEN_ADDRESS")),
                amount: creationFee,
                recipient: vm.envAddress("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT"),
                ceiling: vm.envUint("FORGE_SPONSORED_TASK_FEE_CEILING_USDC")
            })
        );
        bool authorized = registry.owner() == deployer;
        if (authorized) registry.setFactory(address(factoryV2), true);
        vm.stopBroadcast();

        require(factoryV2.controller() == controller, "Sponsored Task vault v2: controller mismatch");
        require(factoryV2.feePolicy() == feePolicy, "Sponsored Task vault v2: fee policy mismatch");
        require(address(factoryV2.registry()) == address(registry), "Sponsored Task vault v2: registry mismatch");
        require(factoryV2.owner() == admin, "Sponsored Task vault v2: fee owner is not the admin");
        require(factoryV2.creationFee() == creationFee, "Sponsored Task vault v2: creation fee mismatch");

        console.log("SponsoredTaskFactoryV2:          ", address(factoryV2));
        console.log("SponsoredTasksVaultV2 (impl):    ", factoryV2.implementation());
        console.log("Vault creation fee (base units): ", creationFee);
        if (authorized) {
            console.log("Registry authorized the v2 factory.");
        } else {
            console.log("The registry owner must authorize the v2 factory:", registry.owner());
            console.log("  to:  ", address(registry));
            console.logBytes(abi.encodeCall(SponsoredTaskRegistry.setFactory, (address(factoryV2), true)));
        }
    }
}
