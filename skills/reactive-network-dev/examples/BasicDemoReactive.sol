// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import '../../../lib/reactive-lib/src/interfaces/IReactive.sol';
import '../../../lib/reactive-lib/src/abstract-base/AbstractReactive.sol';

/// @notice Simplest possible Reactive Contract — "hello world" for Reactive Network.
///
/// Monitors Ping events emitted by BasicDemoCallback on the destination chain.
/// When a Ping is detected, calls pong() on the same contract.
///
/// Deployment order:
///   1. Deploy BasicDemoCallback on Sepolia → save address as CC_ADDRESS
///   2. Deploy BasicDemoReactive on Lasna Testnet with CC_ADDRESS → fund with ETH
///   3. Call BasicDemoCallback.ping(42) on Sepolia → watch for Pong event
contract BasicDemoReactive is IReactive, AbstractReactive {

    // ── Events ────────────────────────────────────────────────────────────────

    event PingDetected(address indexed origin_contract, uint256 value);
    event PongDispatched(uint256 value);

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 private constant DEST_CHAIN_ID = 11155111; // Sepolia

    // keccak256("Ping(address,uint256)") — verified with: cast keccak "Ping(address,uint256)"
    uint256 private constant PING_TOPIC_0 =
        0xfd8d0c1dc3ab254ec49463a1192bb2423b3b851adedec1aa94dcd362dc063c9d;

    uint64 private constant CALLBACK_GAS_LIMIT = 200_000;

    // ── Immutables ────────────────────────────────────────────────────────────

    address public immutable callbackContract;

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param _callbackContract  Address of BasicDemoCallback on Sepolia.
    constructor(address _callbackContract) payable {
        callbackContract = _callbackContract;

        if (!vm) {
            // Subscribe to Ping events emitted by the CC on Sepolia
            service.subscribe(
                DEST_CHAIN_ID,
                callbackContract,
                PING_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // ── react() ───────────────────────────────────────────────────────────────

    /// @notice Called by the ReactVM whenever a subscribed event fires.
    /// No state writes allowed here — only emit Callback.
    function react(LogRecord calldata log) external vmOnly {
        // Ignore events from unexpected contracts
        if (log._contract != callbackContract) return;

        // Decode the value from the Ping event's non-indexed data
        // Ping(address indexed sender, uint256 value) — value is in log.data
        uint256 value = abi.decode(log.data, (uint256));

        emit PingDetected(log._contract, value);

        // Dispatch pong() callback to the CC on Sepolia
        // First arg must be address(0) — RN replaces it with the RVM ID
        emit Callback(
            DEST_CHAIN_ID,
            callbackContract,
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature("pong(address,uint256)", address(0), value)
        );

        emit PongDispatched(value);
    }
}
