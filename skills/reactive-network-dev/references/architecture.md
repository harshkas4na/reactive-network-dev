# Reactive Network Architecture Reference

## LogRecord Struct

The sole parameter to `react()`. Populated by the RN from the monitored event log.

```solidity
struct LogRecord {
    uint256 chain_id;      // Chain ID where the event was emitted
    uint256 block_number;  // Block number of the event
    uint256 op_code;       // Reserved (0 for standard logs)
    address _contract;     // Address of the contract that emitted the event
    uint256 topic_0;       // Event signature hash (keccak256 of full signature)
    uint256 topic_1;       // First indexed parameter (0 if absent)
    uint256 topic_2;       // Second indexed parameter (0 if absent)
    uint256 topic_3;       // Third indexed parameter (0 if absent)
    uint256 block_hash;    // Block hash (as uint256)
    uint256 tx_hash;       // Transaction hash (as uint256)
    uint256 log_index;     // Index of this log in the block
    bytes   data;          // ABI-encoded non-indexed parameters
}
```

Notes:
- `topic_0` is always the event selector for indexed events
- Cron events: `_contract == address(service)`, `topic_0 == cronTopic`
- For address topics: `topic_1 = uint256(uint160(addr))`
- `data` is `abi.decode`-able using the non-indexed parameter types in order

---

## Modifier System

### `vmOnly`
```solidity
modifier vmOnly() {
    require(vm, "RVM only");
    _;
}
```
- Only callable from within the ReactVM (i.e., from the RN's `react()` invocation)
- `vm` is a boolean set to `true` when executing in ReactVM context
- Use on `react()` — prevents calling it from normal transactions

### `rnOnly`
```solidity
modifier rnOnly() {
    require(!vm, "Not for RVM");
    _;
}
```
- Only callable as a real EVM transaction on the Reactive Network
- Use for admin functions like `setCronTopic`, ownership transfers
- Prevents accidental invocation inside ReactVM

### `callbackOnly`
```solidity
modifier callbackOnly() {
    require(msg.sender == RN_CALLBACK_PROXY, "Callback proxy only");
    _;
}
```
- `RN_CALLBACK_PROXY = 0x0000000000000000000000000000000000fffFfF`
- Only callable when the RN's callback proxy executes a self-callback
- Used for state-persistence functions that `react()` emits self-Callbacks to invoke
- These run as full EVM transactions — they CAN call `service.subscribe/unsubscribe`

---

## ISystemContract API

```solidity
interface ISystemContract {
    function subscribe(
        uint256 chain_id,     // Chain to monitor (use block.chainid for RN itself)
        address _contract,    // Contract address to filter (REACTIVE_IGNORE for any)
        uint256 topic_0,      // topic_0 filter (REACTIVE_IGNORE for any)
        uint256 topic_1,      // topic_1 filter (REACTIVE_IGNORE for any)
        uint256 topic_2,      // topic_2 filter (REACTIVE_IGNORE for any)
        uint256 topic_3       // topic_3 filter (REACTIVE_IGNORE for any)
    ) external;

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;
}
```

- `REACTIVE_IGNORE = 0` — wildcard; matches any value in that position
- `service` is the inherited reference to `ISystemContract` in `AbstractReactive`
- `SERVICE_ADDR = 0x0000000000000000000000000000000000FFFFFF` (RN system contract)
- Cron subscription: `chain_id = block.chainid`, `_contract = address(service)`, `topic_0 = cronTopic`

---

## Callback Event

```solidity
event Callback(
    uint256 chain_id,    // Destination chain ID
    address _contract,   // Destination contract address
    uint64  gas_limit,   // Gas limit for the callback execution
    bytes   payload      // ABI-encoded function call
);
```

- Emitting this from `react()` causes the RN to dispatch a call to `_contract` on `chain_id`
- For **self-callbacks** (RC calling itself): `chain_id = block.chainid`, `_contract = address(this)`
- The first parameter in `payload` must be `address(0)` — RN replaces it with the RVM ID at execution time
- Only `Callback` events emitted from `react()` (vmOnly context) are dispatched. Callbacks emitted from `callbackOnly` are **silently ignored**.

---

## AbstractPausableReactive

Base class for pausable RCs. Provides:

```solidity
abstract contract AbstractPausableReactive is AbstractReactive {
    address public owner;
    bool    public paused;

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    function pause()  external rnOnly onlyOwner { /* unsubscribes getPausableSubscriptions() */ }
    function resume() external rnOnly onlyOwner { /* resubscribes getPausableSubscriptions() */ }

    // Override this to declare which subscriptions are managed by pause/resume
    function getPausableSubscriptions()
        internal
        view
        virtual
        returns (Subscription[] memory);

    struct Subscription {
        uint256 chain_id;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
    }
}
```

- Override `getPausableSubscriptions()` to return active cron subscriptions (and any others that should be paused)
- Return an empty array if no pausable subscriptions are currently active
- `pause()`/`resume()` are `rnOnly` — called as regular transactions, not from ReactVM

---

## AbstractCallback

Base class for CC contracts.

```solidity
abstract contract AbstractCallback {
    address private _callbackSender; // The RVM ID of the paired RC

    constructor(address callbackSender) {
        _callbackSender = callbackSender;
    }

    // Checks: msg.sender == RN_CALLBACK_PROXY AND injected sender == _callbackSender
    modifier authorizedSenderOnly() { ... }
}
```

- `_callbackSender` is the **RVM ID** of the RC, not the RC's deploy address
- The RVM ID is deterministic from the RC's deploy address but distinct from it
- Pass the RVM ID (obtained from the RC's deployment receipt or from RN tooling) as `_callbackSender`

---

## Payment Infrastructure

RCs need ETH to pay for callback delivery. Three key functions (available on `AbstractReactive`):

```solidity
function pay(uint256 amount) external;       // Deposit ETH into the RC's RN balance
function coverDebt() external payable;       // Pay outstanding debt
function debt() external view returns (uint256); // Query outstanding debt
```

- Deploy RC with `value` in the constructor call (constructor must be `payable`)
- If the RC runs out of ETH, callbacks stop being delivered
- Add `withdrawAllETH()` and `withdrawETH(amount)` functions to your RC for recovery

---

## Constants

```solidity
uint256 constant REACTIVE_IGNORE = 0;            // Wildcard for subscription filters
address constant RN_CALLBACK_PROXY = 0x0000000000000000000000000000000000fffFfF;
address constant SERVICE_ADDR     = 0x0000000000000000000000000000000000FFFFFF;
```

---

## Chain IDs

| Network              | Chain ID   |
|----------------------|------------|
| Reactive Network     | 1597       |
| Base Mainnet         | 8453       |
| Sepolia              | 11155111   |
| Ethereum Mainnet     | 1          |
| Arbitrum One         | 42161      |
| Optimism             | 10         |
| Polygon              | 137        |

---

## Cron Topics

Cron topics are keccak256 hashes of cron schedule strings. Common ones:

| Interval  | Topic Hash (keccak256)                                                             |
|-----------|------------------------------------------------------------------------------------|
| 1 minute  | `keccak256("reactive-network-cron-1min")`   — verify exact string with RN docs    |
| 5 minutes | `keccak256("reactive-network-cron-5min")`                                          |
| 1 hour    | `keccak256("reactive-network-cron-1h")`                                            |

- When a cron fires: `log._contract == address(service)` and `log.topic_0 == cronTopic`
- Subscribe with: `service.subscribe(block.chainid, address(service), cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE)`
