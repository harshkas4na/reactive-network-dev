# Deployment Guide — Reactive Network

Complete walkthrough from zero to a deployed RC+CC system on testnet.

> **Deployment order:** Always deploy CC first (you need its address for the RC constructor), then deploy RC.

---

## Step 0 — Project Setup

```bash
# Initialize a foundry project (skip if you already have one)
forge init my-reactive-project
cd my-reactive-project

# Install the reactive-lib dependency
forge install Reactive-Network/reactive-lib
```

Add remappings to your `foundry.toml` (or `remappings.txt`):

```toml
# foundry.toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.20"

# Add if using remappings.txt instead:
# remappings = ["reactive-lib/=lib/reactive-lib/"]
```

Or create `remappings.txt`:
```
reactive-lib/=lib/reactive-lib/
```

This allows you to import with `import "reactive-lib/src/..."` in your contracts.

---

## Step 1 — Set Required Environment Variables

```bash
# Your deployer wallet private key (same key for all networks recommended)
export PRIVATE_KEY=<your_private_key>

# Derive your wallet address (used as owner for CC and RC)
export DEPLOYER_ADDR=$(cast wallet address --private-key $PRIVATE_KEY)

# Reactive Lasna Testnet (RC lives here)
export REACTIVE_RPC=https://lasna-rpc.rnk.dev/

# Sepolia (testnet destination chain for CC)
export SEPOLIA_RPC=<your_sepolia_rpc_url>

# Base Sepolia (alternative testnet destination)
export BASE_SEPOLIA_RPC=<your_base_sepolia_rpc_url>
```

> **Using the same private key for all networks** keeps things simple — one `$DEPLOYER_ADDR` as owner on every chain.

---

## Step 2 — Get lREACT Testnet Tokens

lREACT is the testnet gas token for Lasna. Obtain it by sending Sepolia ETH to the faucet.

```bash
# Sepolia faucet — 100 lREACT per 1 ETH sent. Max 5 ETH (= 500 lREACT) per tx.
export SEPOLIA_FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434
cast send $SEPOLIA_FAUCET --value 1ether \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY

# Base Sepolia faucet (alternative)
export BASE_FAUCET=0x2afaFD298b23b62760711756088F75B7409f5967
cast send $BASE_FAUCET --value 1ether \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY
```

> **Warning:** Sending more than 5 ETH per transaction to the faucet loses the excess permanently. Send in multiple transactions if you need more than 500 lREACT.

lREACT appears in your wallet on Lasna Testnet (chain ID 5318007) after a few confirmations.

---

## Step 3 — Deploy CC (Callback Contract) on Destination Chain

Deploy first — you need the CC address as a constructor argument for the RC.

Each destination chain has a **Callback Proxy** address that delivers callbacks to your CC. You must pass the correct proxy for the chain you're deploying to:

```bash
# Callback Proxy addresses (pass as _callbackSender to AbstractCallback):
# Sepolia:          0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA
# Base Sepolia:     0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6
# Unichain Sepolia: 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4
# (See references/architecture.md for full table)

# Example: deploying CC on Sepolia
export CALLBACK_PROXY=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA

forge create src/MyCallback.sol:MyCallback \
  --constructor-args $DEPLOYER_ADDR $CALLBACK_PROXY \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

- First arg: `owner` — who can manage the CC (your wallet)
- Second arg: `_callbackSender` — the **Callback Proxy** for this destination chain (NOT your wallet)

```bash
# Save the deployed address from the output
export CC_ADDRESS=<deployed_address_from_output>
```

---

## Step 4 — Deploy RC (Reactive Contract) on Lasna, Pre-fund with ETH

```bash
forge create src/MyReactive.sol:MyReactive \
  --constructor-args $DEPLOYER_ADDR $CC_ADDRESS \
  --value 0.1ether \
  --rpc-url $REACTIVE_RPC \
  --private-key $PRIVATE_KEY
```

- `--value 0.1ether` pre-funds the RC for callback delivery
- Constructor must be `payable`

```bash
export RC_ADDRESS=<deployed_address_from_output>
```

### Fund RC Later (if needed)

```bash
cast send $RC_ADDRESS --value 0.05ether \
  --rpc-url $REACTIVE_RPC --private-key $PRIVATE_KEY
```

---

## Step 5 — Verify on Reactscan

```
https://lasna.reactscan.net/address/<RC_ADDRESS>
```

Check the contract status:
- `active` — RC has funds; callbacks are being delivered
- `blocklisted` — RC is out of funds; no execution until re-funded

---

## BasicDemo End-to-End (Hello World)

A complete walkthrough using the BasicDemo example contracts:

```bash
# 1. Deploy BasicDemoCallback on Sepolia (use Sepolia's Callback Proxy)
export SEPOLIA_CALLBACK_PROXY=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA

forge create src/BasicDemoCallback.sol:BasicDemoCallback \
  --constructor-args $DEPLOYER_ADDR $SEPOLIA_CALLBACK_PROXY \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY

export CC_ADDRESS=<deployed_address>

# 2. Deploy BasicDemoReactive on Lasna with CC_ADDRESS
forge create src/BasicDemoReactive.sol:BasicDemoReactive \
  --constructor-args $CC_ADDRESS \
  --value 0.1ether \
  --rpc-url $REACTIVE_RPC \
  --private-key $PRIVATE_KEY

export RC_ADDRESS=<deployed_address>

# 3. Trigger a Ping on Sepolia
cast send $CC_ADDRESS "ping(uint256)" 42 \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY

# 4. Wait ~30-60 seconds, then check for Pong event
cast logs --from-block latest --address $CC_ADDRESS \
  --rpc-url $SEPOLIA_RPC

# 5. Verify RC status
echo "https://lasna.reactscan.net/address/$RC_ADDRESS"
```

---

## Quick Reference

**Cron topic hashes** — block-interval based, see `references/architecture.md` for full table:

| Event    | Interval (~time)      | Topic 0                                                              |
|----------|-----------------------|----------------------------------------------------------------------|
| Cron10   | 10 blocks (~1 min)    | `0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687` |
| Cron100  | 100 blocks (~12 min)  | `0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70` |
| Cron1000 | 1000 blocks (~2 hr)   | `0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4` |

**Chain IDs** — see `references/architecture.md` for the full table.

| Network              | Chain ID  | Tier     |
|----------------------|-----------|----------|
| Lasna Testnet (RC)   | 5318007   | Testnet  |
| Reactive Mainnet (RC)| 1597      | Mainnet  |
| Sepolia              | 11155111  | Testnet  |
| Base Sepolia         | 84532     | Testnet  |

> Testnet RC (Lasna) -> testnet destination only. Mainnet RC -> mainnet destination only.
