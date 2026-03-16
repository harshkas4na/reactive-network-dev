# RC Contract Patterns Reference

## Constructor Pattern

```solidity
constructor(
    address _owner,
    address _callbackContract,
    uint256 _cronTopic,
    uint256 _destinationChainId
) payable {
    // 1. Set owner (used by onlyOwner modifier from AbstractPausableReactive)
    owner = _owner;

    // 2. Set immutables — these are the ONLY values react() can reliably read
    callbackContract = _callbackContract;  // immutable
    cronTopic = _cronTopic;                // immutable — NEVER change post-deploy
    destinationChainId = _destinationChainId; // immutable

    // 3. Initialize mutable state
    cronSubscribed = false;
    activeCount = 0;

    // 4. Subscribe — ALWAYS inside if (!vm)
    if (!vm) {
        service.subscribe(
            destinationChainId,
            callbackContract,
            LIFECYCLE_EVENT_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        // Do NOT subscribe to cron here — use lazy subscription in callbackOnly
    }
}
```

**Immutable vs mutable:**
- `immutable`: deploy-time constants readable by `react()`
- `public immutable address callbackContract` — destination
- `public immutable uint256 cronTopic` — cron topic hash
- `public immutable uint256 destinationChainId` — target chain
- Regular storage: written by `callbackOnly`/`rnOnly`, invisible to `react()`

---

## Topic_0 Computation

`topic_0` is the keccak256 hash of the full event signature, including parameter types (no spaces after commas, no parameter names):

```solidity
// Correct:
uint256 private constant MY_EVENT_TOPIC_0 =
    keccak256("MyEvent(uint256,address,uint8)");
// NOT:
//   keccak256("MyEvent(uint256, address, uint8)")  ← spaces = wrong hash
//   keccak256("MyEvent(configId,addr,status)")      ← names = wrong hash
```

**How to derive at development time:**
```bash
# Using cast (foundry):
cast keccak "ProtectionConfigured(uint256,uint8,uint256,uint256,address,address)"
# Output: 0x0379034bb39e80198ee227a7ca9971c0907bea154e437c678febe3f73a241bb0

# Using Python:
python3 -c "from web3 import Web3; print(Web3.keccak(text='ProtectionConfigured(uint256,uint8,uint256,uint256,address,address)').hex())"
```

Always store topic_0 values as `uint256 private constant` with the full event signature in a comment.

---

## react() Routing Pattern

```solidity
function react(LogRecord calldata log) external vmOnly {
    // 1. Check cron FIRST (special case — _contract is address(service))
    if (log.topic_0 == cronTopic) {
        _handleCronTick(log);
        return;
    }

    // 2. Filter by source contract — drop events from other contracts
    if (log._contract != callbackContract) return;

    // 3. Route by topic_0
    if (log.topic_0 == ITEM_CONFIGURED_TOPIC_0) {
        _processItemConfigured(log);
    } else if (log.topic_0 == ITEM_CANCELLED_TOPIC_0) {
        _processItemCancelled(log);
    } else if (log.topic_0 == ITEM_EXECUTED_TOPIC_0) {
        _processItemExecuted(log);
    } else if (log.topic_0 == CYCLE_COMPLETED_TOPIC_0) {
        // Just emit an RC-side event for observability; no callback needed
        emit CycleCompleted(block.timestamp);
    }
}
```

**Important:** Check `cronTopic` before the contract filter. Cron events have `_contract == address(service)`, which is not `callbackContract`, so they'd be dropped if you filter first.

---

## Self-Callback for State Persistence

Since `react()` cannot write state, emit a `Callback` back to `address(this)` to invoke a `callbackOnly` function.

**Critical:** The target `callbackOnly` function MUST have `address` as its first parameter (the sender/RVM ID slot). This is an extra param prepended to your business params. Pass `address(0)` for this slot in the payload — the RN replaces it with the RVM ID.

```solidity
function _processItemConfigured(LogRecord calldata log) internal {
    uint256 itemId = uint256(log.topic_1);
    // Decode non-indexed data
    (uint256 threshold, address asset) = abi.decode(log.data, (uint256, address));

    // Emit self-callback — use address(0) as first arg (RN injects RVM ID)
    emit Callback(
        block.chainid,         // ← RN chain (where this RC lives)
        address(this),         // ← self
        CALLBACK_GAS_LIMIT,
        abi.encodeWithSignature(
            "persistItemConfigured(address,uint256,uint256,address)",
            address(0),        // ← always address(0) for first param
            itemId,
            threshold,
            asset
        )
    );
}
```

Then the state is written in the `callbackOnly` function:
```solidity
function persistItemConfigured(
    address /* sender */,
    uint256 itemId,
    uint256 threshold,
    address asset
) external callbackOnly {
    // All state writes happen here
}
```

---

## callbackOnly Pattern

```solidity
// The callback proxy address on RN
address private constant RN_CALLBACK_PROXY =
    0x0000000000000000000000000000000000fffFfF;

modifier callbackOnly() {
    require(msg.sender == RN_CALLBACK_PROXY, "Callback proxy only");
    _;
}

// All persist functions follow this signature pattern:
// - First arg is address (sender/RVM ID injected by RN, ignored with /* */)
// - Subsequent args are the business parameters
function persistItemCreated(
    address /* sender */,
    uint256 itemId,
    uint256 param
) external callbackOnly {
    if (isTracked[itemId]) return; // Deduplication
    // ... write state ...
    isTracked[itemId] = true;
}
```

---

## Lazy Cron Subscription

Subscribe to cron when the first active item is created; unsubscribe when the last is removed. Do this in `callbackOnly` functions directly (no nested callback needed).

```solidity
function persistItemCreated(address, uint256 itemId, ...) external callbackOnly {
    if (isTracked[itemId]) return;
    isTracked[itemId] = true;
    activeCount++;

    // Lazy subscribe: first active item triggers cron subscription
    if (activeCount == 1 && !cronSubscribed && !paused) {
        service.subscribe(
            block.chainid,
            address(service),
            cronTopic,           // ← immutable, set in constructor
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        cronSubscribed = true;
        emit CronSubscriptionChanged(true, cronTopic);
    }
}

function persistItemCancelled(address, uint256 itemId) external callbackOnly {
    if (!isTracked[itemId]) return;
    if (trackedItems[itemId].status == Status.Active) {
        activeCount--;
        if (activeCount == 0 && cronSubscribed) {
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
    trackedItems[itemId].status = Status.Cancelled;
}
```

---

## getPausableSubscriptions()

Return the list of subscriptions that should be paused when the owner calls `pause()` and restored on `resume()`. Usually just the cron subscription.

```solidity
function getPausableSubscriptions()
    internal
    view
    override
    returns (Subscription[] memory)
{
    if (!cronSubscribed) {
        return new Subscription[](0);
    }
    Subscription[] memory subs = new Subscription[](1);
    subs[0] = Subscription(
        block.chainid,
        address(service),
        cronTopic,
        REACTIVE_IGNORE,
        REACTIVE_IGNORE,
        REACTIVE_IGNORE
    );
    return subs;
}
```

**Notes:**
- Return empty array when `!cronSubscribed` — the base class handles the difference
- Do NOT include event subscriptions (from the destination chain) in the pausable list unless you want them paused too
- `Subscription` struct is defined in `AbstractPausableReactive`

---

## Duplicate Event Guard

Use a mapping to track processed item IDs and return early on duplicates:

```solidity
mapping(uint256 => bool) public isTracked;

function persistItemCreated(address, uint256 itemId, ...) external callbackOnly {
    if (isTracked[itemId]) return;  // Idempotent
    isTracked[itemId] = true;
    // ...
}
```

For event-level deduplication (guarding against re-delivery of the same event):

```solidity
// In the self-callback payload, include the tx_hash
emit Callback(
    block.chainid, address(this), GAS_LIMIT,
    abi.encodeWithSignature(
        "persistItemCreated(address,uint256,uint256)",
        address(0), itemId, log.tx_hash
    )
);

// In callbackOnly:
mapping(uint256 => bool) public processedTxHashes;

function persistItemCreated(address, uint256 itemId, uint256 txHash) external callbackOnly {
    if (processedTxHashes[txHash]) return;
    processedTxHashes[txHash] = true;
    // ...
}
```

---

## Admin / Owner Functions

All owner-callable functions on the RC **must** use `rnOnly onlyOwner`, not just `onlyOwner`. The `rnOnly` modifier ensures the function can only execute as a real EVM transaction on the Reactive Network — never inside the ReactVM. This applies to **all** admin functions including ETH/token withdrawals, config changes, and rescue functions.

```solidity
function withdrawETH(uint256 amount) external rnOnly onlyOwner {
    require(amount <= address(this).balance, "Insufficient balance");
    (bool ok, ) = payable(msg.sender).call{value: amount}("");
    require(ok, "Transfer failed");
}

function withdrawAllETH() external rnOnly onlyOwner {
    uint256 bal = address(this).balance;
    require(bal > 0, "No ETH");
    (bool ok, ) = payable(msg.sender).call{value: bal}("");
    require(ok, "Transfer failed");
}
```

**Why both modifiers?** `rnOnly` prevents ReactVM execution; `onlyOwner` restricts to the deployer. Without `rnOnly`, a malicious event could theoretically cause `react()` to emit a callback that invokes an admin function.

---

## Extracting Data from LogRecord

```solidity
// Indexed parameters come from topics:
uint256 configId = uint256(log.topic_1);
address userAddr = address(uint160(log.topic_2));

// Non-indexed parameters come from data:
// Event: SomeEvent(uint256 indexed id, uint256 param1, address param2)
(uint256 param1, address param2) = abi.decode(log.data, (uint256, address));

// For events with multiple non-indexed params in a struct:
// Event: Sync(uint112 reserve0, uint112 reserve1)  [Uniswap V2]
struct Reserves { uint112 reserve0; uint112 reserve1; }
Reserves memory sync = abi.decode(log.data, (Reserves));
```
