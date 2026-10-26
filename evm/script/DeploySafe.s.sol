// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

interface ISafeSetup {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/// @notice Deploys a Gnosis/Safe wallet via Safe's own canonical factory, for use as a contract
///         admin where an EOA is rejected (e.g. SponsoredTaskFeeBankGuard's `AdminMustBeContract`).
/// @dev Uses Safe v1.4.1's canonical deployment -- the same three addresses on every chain that
///      has them, verified on-chain against Base mainnet (8453) and Base Sepolia (84532) before
///      being hardcoded here (see https://github.com/safe-global/safe-deployments,
///      v1.4.1/{safe_proxy_factory,safe_l2,compatibility_fallback_handler}.json):
///        - SafeProxyFactory:              0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
///        - SafeL2 singleton:              0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
///        - CompatibilityFallbackHandler:  0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99
///      Do not reuse these addresses on a chain without first confirming (`cast codesize`) they
///      resolve to the real Safe contracts there -- canonical deployments are wide but not
///      universal.
contract DeploySafe is Script {
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    /// @dev Env inputs:
    ///      SAFE_DEPLOYER_KEY   -- private key broadcasting this deployment (pays gas only; need
    ///                             not be a Safe owner).
    ///      SAFE_OWNERS         -- comma-separated owner addresses, e.g. "0xabc...,0xdef...".
    ///      SAFE_THRESHOLD      -- signature threshold (must be >0 and <= number of owners).
    ///      SAFE_SALT_NONCE     -- optional; defaults to 0. Change it if you need a second Safe
    ///                             from the same owner set/threshold (the proxy address is
    ///                             deterministic on (singleton, initializer, saltNonce)).
    function run() external returns (address safe) {
        uint256 deployerKey = vm.envUint("SAFE_DEPLOYER_KEY");
        address[] memory owners = vm.envAddress("SAFE_OWNERS", ",");
        uint256 threshold = vm.envUint("SAFE_THRESHOLD");
        uint256 saltNonce = vm.envOr("SAFE_SALT_NONCE", uint256(0));

        require(owners.length > 0, "DeploySafe: no owners");
        require(threshold > 0 && threshold <= owners.length, "DeploySafe: bad threshold");
        require(SAFE_PROXY_FACTORY.code.length != 0, "DeploySafe: factory not deployed on this chain");
        require(SAFE_L2_SINGLETON.code.length != 0, "DeploySafe: singleton not deployed on this chain");

        bytes memory initializer = abi.encodeCall(
            ISafeSetup.setup,
            (owners, threshold, address(0), "", SAFE_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );

        vm.startBroadcast(deployerKey);
        safe = ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_L2_SINGLETON, initializer, saltNonce);
        vm.stopBroadcast();

        require(safe.code.length != 0, "DeploySafe: proxy has no code");

        console2.log("Safe deployed", safe);
        console2.log("Owners", owners.length);
        console2.log("Threshold", threshold);
    }
}
