// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Mintable mock USDC with EIP-3009 transfer authorizations, for disposable
///         preview/sandbox chains. X402's exact scheme settles via
///         transferWithAuthorization, so whatever token stands in for USDC must implement
///         EIP-3009 -- a plain ERC20 reverts at settlement. The EIP-712 domain uses "USD
///         Coin" (mainnet Base USDC's domain) -- set USDC_DOMAIN_NAME=USD Coin to match.
///         Mint is permissionless for sandbox funding. Do not deploy to real networks.
///
///         Blacklisting follows Circle's FiatToken: a `blacklister` (the deployer, replaceable by
///         itself) lists and unlists addresses, `isBlacklisted(address)` reports membership, and
///         any transfer, mint or approval that touches a listed address reverts with FiatToken's
///         message. It lets a local stack exercise the backend's escrow-party precheck, which
///         reads `isBlacklisted` on Base. Nothing is listed until the blacklister lists it, so
///         the token otherwise behaves as before.
contract MockUSDC is ERC20, EIP712 {
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    mapping(address authorizer => mapping(bytes32 nonce => bool used)) private _authorizationUsed;
    mapping(address account => bool listed) private _blacklisted;

    address public blacklister;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);
    event BlacklisterChanged(address indexed newBlacklister);

    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error InvalidSignature();
    error CallerMustBePayee();

    modifier onlyBlacklister() {
        require(msg.sender == blacklister, "Blacklistable: caller is not the blacklister");
        _;
    }

    modifier notBlacklisted(address account) {
        require(!_blacklisted[account], "Blacklistable: account is blacklisted");
        _;
    }

    constructor() ERC20("USD Coin", "USDC") EIP712("USD Coin", "2") {
        blacklister = msg.sender;
        emit BlacklisterChanged(msg.sender);
        _mint(msg.sender, 10_000_000 * 10 ** 6);
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    function blacklist(address account) external onlyBlacklister {
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unBlacklist(address account) external onlyBlacklister {
        _blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    function updateBlacklister(address newBlacklister) external onlyBlacklister {
        require(newBlacklister != address(0), "Blacklistable: new blacklister is the zero address");
        blacklister = newBlacklister;
        emit BlacklisterChanged(newBlacklister);
    }

    /// @dev As FiatToken: the caller, the owner and the spender of an approval must be unlisted.
    function approve(address spender, uint256 value)
        public
        override
        notBlacklisted(msg.sender)
        notBlacklisted(spender)
        returns (bool)
    {
        return super.approve(spender, value);
    }

    /// @dev As FiatToken's transfer and transferFrom: the caller must be unlisted too.
    function transfer(address to, uint256 value) public override notBlacklisted(msg.sender) returns (bool) {
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override
        notBlacklisted(msg.sender)
        returns (bool)
    {
        return super.transferFrom(from, to, value);
    }

    /// @dev Every balance movement (transfer, transferFrom, the EIP-3009 authorizations, mint)
    ///      reverts when it sends from or to a listed address.
    function _update(address from, address to, uint256 value)
        internal
        override
        notBlacklisted(from)
        notBlacklisted(to)
    {
        super._update(from, to, value);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Permissionless mint; acceptable only because this token never leaves a
    ///         disposable chain.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationUsed[authorizer][nonce];
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _useAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
        _transfer(from, to, value);
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _useAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
        _transfer(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (msg.sender != to) revert CallerMustBePayee();
        _useAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
        _transfer(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (msg.sender != to) revert CallerMustBePayee();
        _useAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
        _transfer(from, to, value);
    }

    function _useAuthorization(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (_authorizationUsed[from][nonce]) revert AuthorizationAlreadyUsed();

        bytes32 structHash = keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce));
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != from) revert InvalidSignature();

        _authorizationUsed[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
    }
}
