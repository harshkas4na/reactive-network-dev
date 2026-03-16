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
    address private _callbackSender; // The Callback Proxy for this destination chain

    constructor(address callbackSender) {
        _callbackSender = callbackSender;
    }

    // Checks: msg.sender == _callbackSender (the chain's Callback Proxy)
    modifier authorizedSenderOnly() { ... }
}
```

- `_callbackSender` is the **Callback Proxy address** for the chain where the CC is deployed
- Each destination chain has its own Callback Proxy — see the Chain IDs table below
- Example: CC on Sepolia → pass `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA`
- Example: CC on Base Mainnet → pass `0x0D3E76De6bC44309083cAAFdB49A088B8a250947`
- **This is NOT your wallet address or the RC's address** — it is a protocol-level proxy per chain

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

## Chain IDs & Callback Proxies

Each destination chain has a **Callback Proxy** address — this is the address that delivers callbacks to your CC. Pass it as `_callbackSender` when deploying `AbstractCallback`.

> **Kopli is deprecated.** Use Lasna Testnet for all new development.

### Mainnet Chains

| Chain        | Chain ID | Origin | Dest | Callback Proxy                               |
|--------------|----------|--------|------|----------------------------------------------|
| Reactive     | 1597     | yes    | yes  | `0x0000000000000000000000000000000000fffFfF`  |
| Ethereum     | 1        | yes    | yes  | `0x1D5267C1bb7D8bA68964dDF3990601BDB7902D76`  |
| Base         | 8453     | yes    | yes  | `0x0D3E76De6bC44309083cAAFdB49A088B8a250947`  |
| Arbitrum     | 42161    | yes    | yes  | `0x4730c58FDA9d78f60c987039aEaB7d261aAd942E`  |
| Avalanche    | 43114    | yes    | yes  | `0x934Ea75496562D4e83E80865c33dbA600644fCDa`  |
| BSC          | 56       | yes    | yes  | `0xdb81A196A0dF9Ef974C9430495a09B6d535fAc48`  |
| Abstract     | 2741     | yes    | yes  | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`  |
| HyperEVM     | 999      | yes    | yes  | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`  |
| Linea        | 59144    | yes    | yes  | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`  |
| Plasma       | 9745     | yes    | yes  | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`  |
| Sonic        | 146      | yes    | yes  | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`  |
| Unichain     | 130      | yes    | yes  | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`  |

### Testnet Chains

| Chain            | Chain ID   | Origin | Dest | Callback Proxy                               |
|------------------|------------|--------|------|----------------------------------------------|
| Reactive Lasna   | 5318007    | yes    | yes  | `0x0000000000000000000000000000000000fffFfF`  |
| Ethereum Sepolia | 11155111   | yes    | yes  | `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA`  |
| Base Sepolia     | 84532      | yes    | yes  | `0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6`  |
| Unichain Sepolia | 1301       | yes    | yes  | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`  |
| Avalanche Fuji   | 43113      | yes    | no   | —                                            |
| BSC Testnet      | 97         | yes    | no   | —                                            |
| Polygon Amoy     | 80002      | yes    | no   | —                                            |

### RPC Endpoints

| Network          | RPC                              |
|------------------|----------------------------------|
| Reactive Mainnet | `https://mainnet-rpc.rnk.dev/`   |
| Reactive Lasna   | `https://lasna-rpc.rnk.dev/`     |

> **Critical:** Mainnet and testnet chains cannot be mixed. If the origin is a testnet, the destination must also be a testnet.
>
> **Origin-only chains** (Avalanche Fuji, BSC Testnet, Polygon Amoy) can be monitored for events but cannot receive callbacks.

---

## Cron Topics

Cron events fire based on **block intervals** on the Reactive Network (~7 second block time). There are exactly 5 cron events available — these are protocol-defined topic hashes, not user-computable:

| Event     | Interval          | Approx. Time | Topic 0                                                              |
|-----------|-------------------|--------------|----------------------------------------------------------------------|
| Cron1     | Every block       | ~7 seconds   | `0xf02d6ea5c22a71cffe930a4523fcb4f129be6c804db50e4202fb4e0b07ccb514` |
| Cron10    | Every 10 blocks   | ~1 minute    | `0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687` |
| Cron100   | Every 100 blocks  | ~12 minutes  | `0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70` |
| Cron1000  | Every 1000 blocks | ~2 hours     | `0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4` |
| Cron10000 | Every 10000 blocks| ~28 hours    | `0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56` |

- When a cron fires: `log._contract == address(service)` and `log.topic_0 == cronTopic`
- Subscribe with: `service.subscribe(block.chainid, address(service), cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE)`
- Use the hash directly as a `uint256` constant in Solidity
- These are the ONLY cron intervals available — there are no custom intervals

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
