// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/TaskMarket.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address usdcToken = vm.envAddress("FORGE_USDC_TOKEN_ADDRESS");
        address feeRecipient = vm.envAddress("FORGE_FEE_RECIPIENT_ADDRESS");
        uint16 defaultFeeBps = uint16(vm.envUint("FORGE_DEFAULT_PLATFORM_FEE_BPS"));
        address reputationRegistry = vm.envAddress("FORGE_ERC8004_REPUTATION_REGISTRY");
        address serverAddress = vm.envAddress("FORGE_SERVER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        TaskMarket implementation = new TaskMarket();
        bytes memory initData = abi.encodeCall(
            TaskMarket.initialize, (usdcToken, feeRecipient, defaultFeeBps)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        TaskMarket market = TaskMarket(address(proxy));
        market.addForwarder(serverAddress);
        market.setReputationRegistry(reputationRegistry);

        console.log("Proxy (CONTRACT_ADDRESS):", address(proxy));
        console.log("Implementation:", address(implementation));
        console.log("USDC Token:", usdcToken);
        console.log("Fee Recipient:", feeRecipient);
        console.log("Default Fee BPS:", defaultFeeBps);
        console.log("Reputation registry:", reputationRegistry);
        console.log("Trusted forwarder:", serverAddress);

        vm.stopBroadcast();
    }
}
