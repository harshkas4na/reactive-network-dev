// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2024-2026 Harsh Kasana
pragma solidity >=0.8.0;

import "../lib/reactive-lib/src/interfaces/IReactive.sol";
import "../lib/reactive-lib/src/abstract-base/AbstractPausableReactive.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PersonalAaveProtectionReactive
 * @notice Personal reactive smart contract for monitoring Aave liquidation protection
 * @dev Each user deploys their own instance paired with PersonalAaveProtectionCallback
 */
contract AaveProtectionReactive is IReactive, AbstractPausableReactive {
    event ConfigTracked(uint256 indexed configId);

    event ConfigUntracked(uint256 indexed configId);

    event ProtectionCheckTriggered(uint256 timestamp, uint256 blockNumber);

    event ProtectionCycleCompleted(uint256 timestamp);

    event ProcessingError(string reason, uint256 configId);

    event CronTopicUpdated(uint256 oldTopic, uint256 newTopic);

    event CronSubscriptionChanged(bool subscribed, uint256 topic);

    // Destination chain ID (chain where the callback contract is deployed, e.g. 11155111 for Sepolia, 8453 for Base Mainnet)
    uint256 public immutable destinationChainId;

    uint256 private constant PROTECTION_CONFIGURED_TOPIC_0 =
        0x0379034bb39e80198ee227a7ca9971c0907bea154e437c678febe3f73a241bb0; // keccak256("ProtectionConfigured(uint256,uint8,uint256,uint256,address,address)")
    uint256 private constant PROTECTION_CANCELLED_TOPIC_0 =
        0xcf54734705fd889f6c3dd58ec1a558452d5cd3a3c5ef048ee5b5d925418b90db; // keccak256("ProtectionCancelled(uint256)")
    uint256 private constant PROTECTION_EXECUTED_TOPIC_0 =
        0x9a3c1f530d04162bf90017397efe9a9311e694c35705e3794d59287a95b0e8fe; // keccak256("ProtectionExecuted(uint256,string,address,uint256,uint256,uint256)")
    uint256 private constant PROTECTION_PAUSED_TOPIC_0 =
        0xee6234a3449f904f79d68953452c2b89497ebd146a8bc7ae5b0b4e8f3778a371; // keccak256("ProtectionPaused(uint256)")
    uint256 private constant PROTECTION_RESUMED_TOPIC_0 =
        0x4f84709bd4231f3fd9f66fe6df31a6590e47b2dbb73bd6a1e74d0f3d35474b02; // keccak256("ProtectionResumed(uint256)")
    uint256 private constant PROTECTION_CYCLE_COMPLETED_TOPIC_0 =
        0xb2a1984478c1064cb30b6e5bd7410ed80e897a5a51f65a9c4a826d92ba5a3492; // keccak256("ProtectionCycleCompleted(uint256,uint256,uint256)")
    uint64 private constant CALLBACK_GAS_LIMIT = 2000000;

    // The callback proxy address on the Reactive Network — authenticates self-callbacks
    address private constant RN_CALLBACK_PROXY =
        0x0000000000000000000000000000000000fffFfF;

    // Mirrors the callback contract's ProtectionStatus enum
    enum ProtectionStatus {
        Active,
        Paused,
        Cancelled
    }

    struct TrackedConfig {
        uint256 id;
        uint256 healthFactorThreshold;
        ProtectionStatus status;
        uint256 lastTriggeredAt;
        uint8 triggerCount;
    }

    address public immutable protectionCallback;
    uint256 public cronTopic;

    bool public cronSubscribed;
    uint256 public activeConfigCount;

    mapping(uint256 => TrackedConfig) public trackedConfigs;
    mapping(uint256 => bool) public isTracked;
    uint256[] public configIds; // Track all config IDs for easy enumeration

    // Constants for retry logic
    uint256 private constant TRIGGER_COOLDOWN = 300; // 5 minutes between triggers
    uint8 private constant MAX_TRIGGER_ATTEMPTS = 5;

    // Restrict to calls from the RN callback proxy (self-callbacks)
    modifier callbackOnly() {
        require(msg.sender == RN_CALLBACK_PROXY, "Callback proxy only");
        _;
    }

    constructor(
        address _owner,
        address _protectionCallback,
        uint256 _cronTopic,
        uint256 _destinationChainId
    ) payable {
        owner = _owner;
        protectionCallback = _protectionCallback;
        cronTopic = _cronTopic;
        destinationChainId = _destinationChainId;
        cronSubscribed = false;
        activeConfigCount = 0;

        if (!vm) {
            // Subscribe to protection lifecycle events from the personal callback contract.
            // Cron subscription is NOT set up here — the RC subscribes to cron only when
            // the first active protection config exists, via a self-callback to subscribeToCron().
            service.subscribe(
                destinationChainId,
                protectionCallback,
                PROTECTION_CONFIGURED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            service.subscribe(
                destinationChainId,
                protectionCallback,
                PROTECTION_CANCELLED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            service.subscribe(
                destinationChainId,
                protectionCallback,
                PROTECTION_EXECUTED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            service.subscribe(
                destinationChainId,
                protectionCallback,
                PROTECTION_PAUSED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            service.subscribe(
                destinationChainId,
                protectionCallback,
                PROTECTION_RESUMED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            // Subscribe to ProtectionCycleCompleted events from the callback contract
            // This event is ALWAYS emitted, ensuring the processing flag gets reset
            service.subscribe(
                destinationChainId,
                protectionCallback,
                PROTECTION_CYCLE_COMPLETED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == cronTopic) {
            // CRON event — fire health check.
            // Cron is only subscribed when active configs exist, so no counter
            // guard needed here (VM cannot read callbackOnly state changes).
            emit ProtectionCheckTriggered(block.timestamp, block.number);

            // Callback to destination chain to run Aave health checks
            emit Callback(
                destinationChainId,
                protectionCallback,
                CALLBACK_GAS_LIMIT,
                abi.encodeWithSignature(
                    "checkAndProtectPositions(address)",
                    address(0)
                )
            );
        } else if (
            log._contract == protectionCallback &&
            log.topic_0 == PROTECTION_CYCLE_COMPLETED_TOPIC_0
        ) {
            emit ProtectionCycleCompleted(block.timestamp);
        } else if (log._contract == protectionCallback) {
            _processProtectionEvent(log);
        }
    }

    function subscribeToCron(address /* sender */) external callbackOnly {
        if (!cronSubscribed && !paused) {
            service.subscribe(
                block.chainid,
                address(service),
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            cronSubscribed = true;
            emit CronSubscriptionChanged(true, cronTopic);
        }
    }

    function unsubscribeFromCron(address /* sender */) external callbackOnly {
        if (cronSubscribed) {
            service.unsubscribe(
                block.chainid,
                address(service),
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            cronSubscribed = false;
            emit CronSubscriptionChanged(false, cronTopic);
        }
    }

    function persistConfigCreated(
        address /* sender */,
        uint256 configId,
        uint256 healthFactorThreshold
    ) external callbackOnly {
        if (isTracked[configId]) return;

        trackedConfigs[configId] = TrackedConfig({
            id: configId,
            healthFactorThreshold: healthFactorThreshold,
            status: ProtectionStatus.Active,
            lastTriggeredAt: 0,
            triggerCount: 0
        });

        isTracked[configId] = true;
        configIds.push(configId);

        // Subscribe directly — no nested callback needed (we're in normal tx context)
        if (activeConfigCount == 0 && !cronSubscribed && !paused) {
            service.subscribe(
                block.chainid,
                address(service),
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            cronSubscribed = true;
            emit CronSubscriptionChanged(true, cronTopic);
        }

        activeConfigCount++;
        emit ConfigTracked(configId);
    }

    function persistConfigCancelled(
        address /* sender */,
        uint256 configId
    ) external callbackOnly {
        if (isTracked[configId]) {
            if (trackedConfigs[configId].status == ProtectionStatus.Active) {
                activeConfigCount--;
                if (activeConfigCount == 0 && cronSubscribed) {
                    service.unsubscribe(
                        block.chainid,
                        address(service),
                        cronTopic,
                        REACTIVE_IGNORE,
                        REACTIVE_IGNORE,
                        REACTIVE_IGNORE
                    );
                    cronSubscribed = false;
                    emit CronSubscriptionChanged(false, cronTopic);
                }
            }
            trackedConfigs[configId].status = ProtectionStatus.Cancelled;
            emit ConfigUntracked(configId);
        }
    }

    function persistConfigExecuted(
        address /* sender */,
        uint256 configId
    ) external callbackOnly {
        if (isTracked[configId]) {
            trackedConfigs[configId].lastTriggeredAt = 0;
            trackedConfigs[configId].triggerCount = 0;
        }
    }

    function persistConfigPaused(
        address /* sender */,
        uint256 configId
    ) external callbackOnly {
        if (isTracked[configId]) {
            if (trackedConfigs[configId].status == ProtectionStatus.Active) {
                activeConfigCount--;
                if (activeConfigCount == 0 && cronSubscribed) {
                    service.unsubscribe(
                        block.chainid,
                        address(service),
                        cronTopic,
                        REACTIVE_IGNORE,
                        REACTIVE_IGNORE,
                        REACTIVE_IGNORE
                    );
                    cronSubscribed = false;
                    emit CronSubscriptionChanged(false, cronTopic);
                }
            }
            trackedConfigs[configId].status = ProtectionStatus.Paused;
        }
    }

    function persistConfigResumed(
        address /* sender */,
        uint256 configId
    ) external callbackOnly {
        if (isTracked[configId]) {
            if (trackedConfigs[configId].status == ProtectionStatus.Paused) {
                if (activeConfigCount == 0 && !cronSubscribed && !paused) {
                    service.subscribe(
                        block.chainid,
                        address(service),
                        cronTopic,
                        REACTIVE_IGNORE,
                        REACTIVE_IGNORE,
                        REACTIVE_IGNORE
                    );
                    cronSubscribed = true;
                    emit CronSubscriptionChanged(true, cronTopic);
                }
                activeConfigCount++;
            }
            trackedConfigs[configId].status = ProtectionStatus.Active;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          REACT HELPERS (emit self-callbacks, no direct state writes)
    // ═══════════════════════════════════════════════════════════════════════

    function _processProtectionEvent(LogRecord calldata log) internal {
        if (log.topic_0 == PROTECTION_CONFIGURED_TOPIC_0) {
            _processConfigCreated(log);
        } else if (log.topic_0 == PROTECTION_CANCELLED_TOPIC_0) {
            _processConfigCancelled(log);
        } else if (log.topic_0 == PROTECTION_EXECUTED_TOPIC_0) {
            _processConfigExecuted(log);
        } else if (log.topic_0 == PROTECTION_PAUSED_TOPIC_0) {
            _processConfigPaused(log);
        } else if (log.topic_0 == PROTECTION_RESUMED_TOPIC_0) {
            _processConfigResumed(log);
        }
    }

    // Each _processConfig* function emits a self-Callback to persist state.
    // No state is written directly — react() is vmOnly.

    function _processConfigCreated(LogRecord calldata log) internal {
        uint256 configId = uint256(log.topic_1);

        (, uint256 healthFactorThreshold, , , ) = abi.decode(
            log.data,
            (uint8, uint256, uint256, address, address)
        );

        emit Callback(
            block.chainid,
            address(this),
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature(
                "persistConfigCreated(address,uint256,uint256)",
                address(0),
                configId,
                healthFactorThreshold
            )
        );
    }

    function _processConfigCancelled(LogRecord calldata log) internal {
        uint256 configId = uint256(log.topic_1);

        emit Callback(
            block.chainid,
            address(this),
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature(
                "persistConfigCancelled(address,uint256)",
                address(0),
                configId
            )
        );
    }

    function _processConfigExecuted(LogRecord calldata log) internal {
        uint256 configId = uint256(log.topic_1);

        emit Callback(
            block.chainid,
            address(this),
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature(
                "persistConfigExecuted(address,uint256)",
                address(0),
                configId
            )
        );
    }

    function _processConfigPaused(LogRecord calldata log) internal {
        uint256 configId = uint256(log.topic_1);

        emit Callback(
            block.chainid,
            address(this),
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature(
                "persistConfigPaused(address,uint256)",
                address(0),
                configId
            )
        );
    }

    function _processConfigResumed(LogRecord calldata log) internal {
        uint256 configId = uint256(log.topic_1);

        emit Callback(
            block.chainid,
            address(this),
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature(
                "persistConfigResumed(address,uint256)",
                address(0),
                configId
            )
        );
    }

    function getActiveConfigs() external view returns (uint256[] memory) {
        uint256 activeCount = 0;

        for (uint256 i = 0; i < configIds.length; i++) {
            uint256 configId = configIds[i];
            if (trackedConfigs[configId].status == ProtectionStatus.Active) {
                activeCount++;
            }
        }

        uint256[] memory activeConfigs = new uint256[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < configIds.length; i++) {
            uint256 configId = configIds[i];
            if (trackedConfigs[configId].status == ProtectionStatus.Active) {
                activeConfigs[index] = configId;
                index++;
            }
        }

        return activeConfigs;
    }

    function getPausableSubscriptions()
        internal
        view
        override
        returns (Subscription[] memory)
    {
        if (!cronSubscribed) {
            return new Subscription[](0);
        }
        Subscription[] memory result = new Subscription[](1);
        result[0] = Subscription(
            block.chainid,
            address(service),
            cronTopic,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        return result;
    }

    /**
     * @notice Update the cron topic (e.g. switch from 1-min to 5-min cron)
     * @dev Can only be called on the Reactive Network by the owner. Automatically
     *      re-subscribes to the new topic if currently subscribed (active configs exist
     *      and RC is not globally paused).
     * @param newCronTopic The new cron topic hash to subscribe to
     */
    function setCronTopic(uint256 newCronTopic) external rnOnly onlyOwner {
        require(newCronTopic != cronTopic, "Same cron topic");

        uint256 oldTopic = cronTopic;

        if (cronSubscribed && !paused) {
            service.unsubscribe(
                block.chainid,
                address(service),
                oldTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            cronTopic = newCronTopic;
            service.subscribe(
                block.chainid,
                address(service),
                newCronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        } else {
            cronTopic = newCronTopic;
        }

        emit CronTopicUpdated(oldTopic, newCronTopic);
    }

    function getProtectionCallback() external view returns (address) {
        return protectionCallback;
    }

    function getCronTopic() external view returns (uint256) {
        return cronTopic;
    }

    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external rnOnly onlyOwner {
        require(to != address(0), "Invalid recipient address");
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function rescueAllERC20(address token, address to) external rnOnly onlyOwner {
        require(to != address(0), "Invalid recipient address");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to rescue");
        SafeERC20.safeTransfer(IERC20(token), to, balance);
    }

    // Emergency withdrawal functions - only deployer can call
    function withdrawETH(uint256 amount) external rnOnly onlyOwner {
        require(amount <= address(this).balance, "Insufficient ETH balance");

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function withdrawAllETH() external rnOnly onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");

        (bool success, ) = payable(msg.sender).call{value: balance}("");
        require(success, "ETH transfer failed");
    }
}
