// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskFeeBankDepositor } from "../src/hooks/sponsored-task/SponsoredTaskFeeBankDepositor.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { ISponsoredTaskFeeBank } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskFeeBank.sol";

/// @notice Deploys `SponsoredTaskFactoryV2` and `SponsoredTaskFeeBankDepositor` beside an
///         existing Sponsored Task stack.
/// @dev The v2 factory takes its controller (the hook), fee policy and registry from the deployed
///      v1 factory, so both factories create vaults for the same hook under the same fee terms.
///      The registry must authorize the new factory before it can create a vault; when the
///      deployer does not own the registry (normally the guard-admin Safe does), the script prints
///      the call for the owner to execute instead.
///
///      Env: FORGE_DEV_PRIVATE_KEY, FORGE_SPONSORED_TASK_FACTORY_ADDRESS (the v1 factory),
///      FORGE_SPONSORED_TASK_FEE_BANK_ADDRESS.
contract DeploySponsoredTaskVaultV2 is Script {
    function run() external returns (SponsoredTaskFactoryV2 factoryV2, SponsoredTaskFeeBankDepositor depositor) {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        SponsoredTaskFactory factoryV1 = SponsoredTaskFactory(vm.envAddress("FORGE_SPONSORED_TASK_FACTORY_ADDRESS"));
        address feeBank = vm.envAddress("FORGE_SPONSORED_TASK_FEE_BANK_ADDRESS");
        require(address(factoryV1).code.length != 0, "Sponsored Task vault v2: missing v1 factory code");
        require(feeBank.code.length != 0, "Sponsored Task vault v2: missing fee bank code");

        SponsoredTaskRegistry registry = SponsoredTaskRegistry(address(factoryV1.registry()));
        address controller = factoryV1.controller();
        address feePolicy = factoryV1.feePolicy();

        vm.startBroadcast(deployerKey);
        factoryV2 = new SponsoredTaskFactoryV2(controller, feePolicy, registry);
        depositor = new SponsoredTaskFeeBankDepositor(ISponsoredTaskFeeBank(feeBank));
        bool authorized = registry.owner() == deployer;
        if (authorized) registry.setFactory(address(factoryV2), true);
        vm.stopBroadcast();

        require(factoryV2.controller() == controller, "Sponsored Task vault v2: controller mismatch");
        require(factoryV2.feePolicy() == feePolicy, "Sponsored Task vault v2: fee policy mismatch");
        require(address(factoryV2.registry()) == address(registry), "Sponsored Task vault v2: registry mismatch");
        require(address(depositor.feeBank()) == feeBank, "Sponsored Task vault v2: fee bank mismatch");

        console.log("SponsoredTaskFactoryV2:          ", address(factoryV2));
        console.log("SponsoredTaskFeeBankDepositor:   ", address(depositor));
        console.log("SponsoredTasksVaultV2 (impl):    ", factoryV2.implementation());
        if (authorized) {
            console.log("Registry authorized the v2 factory.");
        } else {
            console.log("The registry owner must authorize the v2 factory:", registry.owner());
            console.log("  to:  ", address(registry));
            console.logBytes(abi.encodeCall(SponsoredTaskRegistry.setFactory, (address(factoryV2), true)));
        }
    }
}
