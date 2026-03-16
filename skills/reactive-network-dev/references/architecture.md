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
- **The target function MUST have `address` as its first parameter** (the sender/RVM ID slot). This is an extra parameter prepended to your business params. In the `payload`, always pass `address(0)` for this slot — the RN replaces it with the RVM ID at execution time.
  - If business logic needs `(uint256 id, string msg)`, the function is `fn(address sender, uint256 id, string msg)` and the payload is `abi.encodeWithSignature("fn(address,uint256,string)", address(0), id, msg)`
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

- `_callbackSender` is the **RVM ID** — this is the **EOA address** (wallet) used to deploy the RC on the Reactive Network
- It is NOT the RC's deployed contract address — it is your deployer wallet address
- If deploying RC and CC from the same wallet, pass that wallet address as `_callbackSender`

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

### Reactive Network

| Network              | Chain ID   | RPC                              |
|----------------------|------------|----------------------------------|
| Reactive Mainnet     | 1597       | `https://mainnet-rpc.rnk.dev/`   |
| Lasna Testnet        | 5318007    | `https://lasna-rpc.rnk.dev/`     |

> **Kopli is deprecated.** Use Lasna Testnet for all new development.

### Destination Chains — Mainnet

| Network          | Chain ID |
|------------------|----------|
| Ethereum Mainnet | 1        |
| Base Mainnet     | 8453     |
| Arbitrum One     | 42161    |
| Optimism         | 10       |
| Polygon          | 137      |
| HyperEVM         | 999      |
| Abstract         | 2741     |
| Sonic            | 146      |
| Soneium          | 1868     |
| Unichain         | 130      |

### Destination Chains — Testnet

| Network          | Chain ID   |
|------------------|------------|
| Sepolia          | 11155111   |
| Base Sepolia     | 84532      |
| Unichain Sepolia | 1301       |

> **Critical:** Mainnet and testnet chains cannot be mixed. Lasna Testnet RC can only deliver callbacks to testnet destination chains. Reactive Mainnet RC can only deliver callbacks to mainnet destination chains.

---

## Cron Topics

Cron topics are keccak256 hashes of fixed cron schedule strings:

| Interval   | String                          | Topic Hash                                                           |
|------------|---------------------------------|----------------------------------------------------------------------|
| 1 minute   | `reactive-network-cron-1min`    | `0x10f4e58e062105477d72f60b69049586448b6c43bf40e7c334b1093b0e965d57` |
| 5 minutes  | `reactive-network-cron-5min`    | `0x397d353798eb2ffcee4f62aad18906fd441cb6813b7d145398d4f170b6b976c2` |
| 10 minutes | `reactive-network-cron-10min`   | `0x920d4adf25816805d3fbf353ccffae0c45c9e96e0f300652fe9f6a0850f5ae51` |
| 30 minutes | `reactive-network-cron-30min`   | `0xdd28b4975b796a4118a568621c33b661dc1184b5ab53b97f894920fecc8f9409` |
| 1 hour     | `reactive-network-cron-1hr`     | `0x1c0a1b9e81bd760da4242b10e7a82d11ddfba3691c444fb8c451375f6642c1bd` |
| 6 hours    | `reactive-network-cron-6hr`     | `0x42da5f3b2a4fba938334bf220a817e1114d20f016647ba21bc137d7184d35eb5` |
| 24 hours   | `reactive-network-cron-24hr`    | `0xdc9b69ea20fe15b408d4b8001a11811444022199c88ab26b69fa62b356c96ab5` |

- When a cron fires: `log._contract == address(service)` and `log.topic_0 == cronTopic`
- Subscribe with: `service.subscribe(block.chainid, address(service), cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE)`
- Use the hash directly as a `uint256` constant in Solidity (already a 32-byte value)

---

## Economics

### Fee Formula

- **RC execution fee:** `fee = BaseFee × GasUsed` (charged from RC's on-chain ETH balance)
- **Cross-chain callback fee:** `p_callback = p_base × C × (g_callback + K)`
  - `C` = destination chain coefficient (varies by chain)
  - `g_callback` = gas limit specified in the `Callback` event
  - `K` = fixed surcharge per callback

### Gas Limits

| Parameter              | Value     | Notes                                               |
|------------------------|-----------|-----------------------------------------------------|
| Min callback gas limit | 100,000   | System enforces this; lower values are raised/rejected |
| Max RC gas limit       | 900,000   | Hard cap per `react()` invocation                   |
| Recommended CC gas     | 1,000,000–2,000,000 | For complex CC logic                      |

### Contract Status

- `active` — RC has sufficient ETH balance; callbacks are delivered
- `blocklisted` — RC has run out of ETH; no callbacks delivered until funded

Monitor status at: `https://lasna.reactscan.net/address/<RC_ADDRESS>` (testnet) or `https://reactscan.net/address/<RC_ADDRESS>` (mainnet)

---

## Multi-Chain Subscription Patterns

```solidity
// Subscribe to all chains (chain_id = 0 = wildcard)
service.subscribe(0, specificContract, specificTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);

// Subscribe to all contracts on a chain (_contract = address(0) = wildcard)
service.subscribe(SEPOLIA_CHAIN_ID, address(0), specificTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
```

**Constraint:** At least one of `(chain_id, _contract, topic_0)` must be non-zero (non-wildcard). Subscribing with all three as wildcards is rejected.

---

## DIA Oracle Integration

DIA provides price feeds on Base Mainnet that emit events on >1% price change OR every 24 hours (minimum).

**Oracle contract (Base Mainnet):** `0x5612599CF48032d7428399d5Fcb99eDcc75c06A7`

**Price update event:**
```solidity
// DIA emits this on price changes
event OracleUpdate(string key, uint128 value, uint128 timestamp);
```

**RC subscription pattern:**
```solidity
// keccak256("OracleUpdate(string,uint128,uint128)")
uint256 private constant DIA_ORACLE_UPDATE_TOPIC_0 = ...; // compute with cast keccak

// In constructor:
if (!vm) {
    service.subscribe(
        8453,                    // Base Mainnet
        0x5612599CF48032d7428399d5Fcb99eDcc75c06A7, // DIA oracle
        DIA_ORACLE_UPDATE_TOPIC_0,
        REACTIVE_IGNORE,
        REACTIVE_IGNORE,
        REACTIVE_IGNORE
    );
}
```

**In `react()`:** decode `log.data` to get the price key (e.g. `"ETH/USD"`), value (18-decimal fixed-point), and timestamp. Use these to trigger cross-chain actions when price conditions are met.
