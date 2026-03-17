// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPGTRForwarder} from "./interfaces/IPGTRForwarder.sol";

/**
 * @title TaskMarketForwarder
 * @notice PGTR forwarder for TaskMarket (ERC-8194).
 *
 *         This contract is the single trusted entry point for the TaskMarket
 *         backend server. It implements IPGTRForwarder so that TaskMarket can
 *         read the authenticated actor via pgtrSender() rather than relying on
 *         explicit calldata parameters.
 *
 *         Flow for each operation:
 *         1. Backend server (msg.sender) calls relay(pgtrSender, paymentAmount, data).
 *         2. If paymentAmount > 0, the forwarder pulls USDC from msg.sender directly
 *            into TaskMarket using transferFrom (server must have approved this contract).
 *         3. The forwarder sets _pgtrSenderStorage = pgtrSender for the duration of
 *            the TaskMarket call.
 *         4. The forwarder calls TaskMarket with the provided calldata.
 *         5. _pgtrSenderStorage is reset to address(0).
 *         6. PaymentGatedCall is emitted.
 *
 *         TaskMarket reads the authenticated actor via:
 *           IPGTRForwarder(msg.sender).pgtrSender()
 *         This returns the pgtrSender set in step 3.
 *
 *         Receipt replay protection uses keccak256(pgtrSender, paymentAmount,
 *         receiptNonce, validBefore, taskMarket, selector) to prevent duplicate relays.
 */
contract TaskMarketForwarder is IPGTRForwarder, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public immutable taskMarket;
    address public immutable authorizedRelayer;

    address private _pgtrSenderStorage;

    mapping(bytes32 => bool) public consumedReceipts;

    error ReceiptAlreadyConsumed();
    error ReceiptExpired();
    error ReceiptNotYetValid();
    error RelayFailed();
    error UnauthorizedRelayer();

    constructor(address _usdc, address _taskMarket, address _authorizedRelayer) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_taskMarket != address(0), "Invalid TaskMarket address");
        require(_authorizedRelayer != address(0), "Invalid relayer address");
        usdc = IERC20(_usdc);
        taskMarket = _taskMarket;
        authorizedRelayer = _authorizedRelayer;
    }

    // -------------------------------------------------------------------------
    // IPGTRForwarder
    // -------------------------------------------------------------------------

    /// @inheritdoc IPGTRForwarder
    function isPGTRForwarder() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IPGTRForwarder
    function pgtrSender() external view override returns (address) {
        require(_pgtrSenderStorage != address(0), "No active forwarded call");
        return _pgtrSenderStorage;
    }

    /// @inheritdoc IPGTRForwarder
    /// @dev This forwarder only trusts itself. External contracts that are PGTR
    ///      destinations call this to verify that a given msg.sender is a legitimate
    ///      PGTR forwarder before reading pgtrSender(). Returning true for address(this)
    ///      means TaskMarket (or any other destination) can safely call
    ///      IPGTRForwarder(msg.sender).pgtrSender() when msg.sender == address(this).
    function isTrustedForwarder(address addr) external view override returns (bool) {
        return addr == address(this);
    }

    // -------------------------------------------------------------------------
    // ERC-165
    // -------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPGTRForwarder).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // -------------------------------------------------------------------------
    // Relay
    // -------------------------------------------------------------------------

    /**
     * @notice Relay a call to TaskMarket with payment-gated authorization.
     * @param pgtrSenderAddr  The authenticated actor on whose behalf the call is made.
     *                        TaskMarket reads this via pgtrSender() to attribute the action.
     * @param paymentAmount   USDC amount to pull from msg.sender into TaskMarket escrow.
     *                        Pass 0 for operations with no payment (e.g. submitWork).
     * @param validBefore     Unix timestamp after which this receipt is invalid.
     * @param receiptNonce    Unique bytes32 per (pgtrSender, operation) to prevent replay.
     * @param data            ABI-encoded calldata for the TaskMarket function.
     */
    function relay(
        address pgtrSenderAddr,
        uint256 paymentAmount,
        uint256 validBefore,
        bytes32 receiptNonce,
        bytes calldata data
    ) external nonReentrant {
        if (msg.sender != authorizedRelayer) revert UnauthorizedRelayer();
        if (block.timestamp > validBefore) revert ReceiptExpired();

        bytes4 selector = bytes4(data[:4]);
        bytes32 receiptHash = keccak256(abi.encode(
            block.chainid, pgtrSenderAddr, paymentAmount, receiptNonce, validBefore, taskMarket, selector
        ));
        if (consumedReceipts[receiptHash]) revert ReceiptAlreadyConsumed();
        consumedReceipts[receiptHash] = true;

        if (paymentAmount > 0) {
            usdc.safeTransferFrom(msg.sender, taskMarket, paymentAmount);
        }

        _pgtrSenderStorage = pgtrSenderAddr;
        (bool success, bytes memory result) = taskMarket.call(data);
        _pgtrSenderStorage = address(0);

        if (!success) {
            if (result.length == 0) revert RelayFailed();
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        emit PaymentGatedCall(pgtrSenderAddr, taskMarket, selector, paymentAmount);
    }
}
