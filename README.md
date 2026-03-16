# reactive-network-dev

A Claude Code skill that teaches Claude how to design and implement **Reactive Network** smart contract systems — the two-contract architecture (RC + CC) for cross-chain event-driven automation.

## What This Does

When installed, Claude gains deep knowledge of:

- **Reactive Contract (RC) patterns** — `react()` routing, self-callbacks, lazy cron subscription, subscription management, the frozen ReactVM state model
- **Callback Contract (CC) patterns** — `authorizedSenderOnly` entry points, try-catch isolation, lifecycle events, auto-cancel on consecutive failures
- **12 critical gotchas** discovered through real debugging (each one cost hours to find)
- **Deployment workflows** — from `forge install` to funded RC verified on Reactscan
- **Cron topic hashes** — pre-computed keccak256 values for all 7 intervals
- **Chain IDs** — Reactive Mainnet, Lasna Testnet, and all supported destination chains
- **Working examples** — BasicDemo (hello world), Uniswap stop-order, Aave liquidation protection

## Installation

### Option A: Global Skill (recommended — works for all projects)

Clone the repo and symlink the skill directory into your Claude config's `skills/` folder:

```bash
# Clone the repo anywhere you like
git clone https://github.com/harshkas4na/reactive-network-dev.git
cd reactive-network-dev

# Find your Claude config directory:
#   Default:         ~/.claude
#   Custom (common): check if you have CLAUDE_CONFIG_DIR set in your shell aliases
#   Example:         ~/.claude-work, ~/.claude-personal, etc.
#
# To check: run `alias | grep claude` — look for CLAUDE_CONFIG_DIR=<path>

# Create the global skills directory (replace ~/.claude with YOUR config dir)
mkdir -p ~/.claude/skills

# Symlink the skill into it
ln -s "$(pwd)/skills/reactive-network-dev" ~/.claude/skills/reactive-network-dev
```

> **Custom config dirs:** If you use aliases like `claude-work` or `claude-personal` that set `CLAUDE_CONFIG_DIR`, put the symlink in THAT directory's `skills/` folder. Example: if your alias sets `CLAUDE_CONFIG_DIR=~/.claude-work`, then: `mkdir -p ~/.claude-work/skills && ln -s "$(pwd)/skills/reactive-network-dev" ~/.claude-work/skills/reactive-network-dev`

### Option B: Project-Local Skill (only available in one project)

If you only want the skill in a specific project:

```bash
# From your project root
mkdir -p .claude/skills
ln -s /path/to/reactive-network-dev/skills/reactive-network-dev .claude/skills/reactive-network-dev
```

### Option C: Plugin Mode (per-session, for testing)

```bash
claude --plugin-dir /path/to/reactive-network-dev
```

## Verify Installation

After installing, **start a new Claude Code session** (skills load at session start):

```bash
claude
```

Then type `/` and look for `reactive-network-dev` in the autocomplete list. If you see it, the skill is loaded.

You can also trigger it directly:

```
> /reactive-network-dev
```

Or just ask Claude naturally — it auto-triggers on phrases like "write a reactive contract", "create an RC system", etc.

> **Note:** `claude plugins list` does NOT show standalone skills. Skills installed in `~/.claude/skills/` or `.claude/skills/` are loaded silently at session start. The `/` autocomplete menu is the way to verify them.

## Usage

Once installed, Claude will automatically use the skill when you ask it to:

- "Write a reactive contract that monitors Uniswap price events"
- "Create an RC/CC system for Aave liquidation protection"
- "Scaffold a cron-based reactive contract"
- "Build a cross-chain automation that reacts to token transfers"

The skill triggers on phrases like: *"reactive contract"*, *"callback contract"*, *"RC and CC"*, *"reactive network"*, *"cross-chain automation"*, *"cron-based reactive"*.

## Project Structure

```
skills/reactive-network-dev/
  SKILL.md                              # Main skill prompt — templates, rules, workflow
  references/
    architecture.md                     # LogRecord, modifiers, APIs, chain IDs, cron hashes, economics
    deployment.md                       # Step-by-step deployment guide
    rc-patterns.md                      # RC constructor, react() routing, self-callbacks, cron
    cc-patterns.md                      # CC entry points, try-catch, lifecycle events
    gotchas.md                          # 12 critical pitfalls with code examples
  examples/
    BasicDemoReactive.sol               # Minimal hello-world RC (Ping -> Pong)
    BasicDemoCallback.sol               # Minimal hello-world CC
    UniswapDemoStopOrderReactive.sol    # Event-triggered Uniswap stop-order RC
    UniswapDemoStopOrderCallback.sol    # Uniswap swap execution CC
    AaveProtectionReactive.sol          # Complex cron-based Aave protection RC
    AaveProtectionCallback.sol          # Multi-config Aave protection CC
```

## Key Concepts

**Two-contract architecture:** Every system has an RC (on Reactive Network) and a CC (on a destination chain like Base or Sepolia). They communicate exclusively via events.

**ReactVM is frozen:** `react()` runs in a snapshot taken at deployment. It can only read `immutable` variables and constructor-assigned values. Post-deployment state writes are invisible to it.

**Self-callbacks for state persistence:** Since `react()` can't write state, it emits `Callback` events to `address(this)`, which the RN delivers as real transactions to `callbackOnly` functions that CAN write state.

**Lazy cron subscription:** Don't subscribe to cron in the constructor. Subscribe in a `callbackOnly` function when the first active item is created; unsubscribe when the last is cancelled.

## Prerequisites

- [Foundry](https://getfoundry.sh/) (`forge`, `cast`)
- A wallet with Sepolia ETH (for testnet development)
- lREACT tokens (obtainable via faucet — see `references/deployment.md`)

## Verifying Hashes

All topic hashes in this skill were computed with `cast keccak` (Foundry). **Do not use Node.js `crypto.createHash('sha3-256')`** — that produces NIST SHA3-256, which is a different algorithm from Ethereum's keccak256. Hashes will be silently wrong.

```bash
# Correct way to compute topic hashes:
cast keccak "EventName(type1,type2)"

# Example:
cast keccak "Ping(address,uint256)"
# 0xfd8d0c1dc3ab254ec49463a1192bb2423b3b851adedec1aa94dcd362dc063c9d
```

## Contributing

If you find errors, missing patterns, or new gotchas, please open an issue or PR. The skill is organized so that each file covers one concern — add new gotchas to `gotchas.md`, new patterns to `rc-patterns.md` or `cc-patterns.md`, new examples to `examples/`.

## Author

Harsh Kasana
