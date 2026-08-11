# Where is metadata stored?

## Short answer for Axiom

| Product | Singleton factory launch event? | Name / ticker on event? | Image / socials / description |
|---------|----------------------------------|-------------------------|-------------------------------|
| **Instant V3** | Yes — `TokenLaunched` on factory `0xeE6D…` | **No** — read ERC20 + token views | **On-chain on the token**: `logo()`, `description()`, `socials()` |
| **Instant V4** | Yes — `V4TokenLaunched` on factory `0x6079…` | **No** | Same: `PeepsV4Token` `logo` / `description` / `socials` |
| **Bonding V3** | Yes — `TokenCreated` on factory `0x84A9…` | **Yes** (`name`, `symbol`) | **Off-chain URI on the event**: `metadataUri` + integrity `metadataHash` |
| **Bonding V4** | Yes — `TokenCreated` on factory `0xEEb8…` | **Yes** | Same `metadataUri` / `metadataHash` on event |

### Instant (V3 & V4) — no metadata URI on the factory event
- The factory emits a launch event with **token address / deployer / pool (or poolId)** only.
- Image URL and social links are written into the **token contract storage at deploy** (constructor args from `launchToken`).
- Indexer pattern: watch factory → `eth_call` token metadata getters.

Minimal Instant token reads:

```solidity
function name() view returns (string);
function symbol() view returns (string);
function logo() view returns (string);          // image URL / CID string
function description() view returns (string);
function socials() view returns (string twitter, string telegram, string discord, string website, string farcaster);
function getTokenInfo() view returns (...);    // Instant V3 convenience
```

ABIs: `abis/token-metadata/PeepsToken.abi.json`, `PeepsV4Token.abi.json`.

### Bonding (V3 & V4) — metadata URI **is** on the factory event
`TokenCreated` includes:
- `name`, `symbol`
- `metadataHash` (keccak256 of canonical metadata JSON)
- `metadataUri` — typically `data:application/json;base64,...` or `ipfs://...` / HTTPS

Expected JSON fields after resolving URI: `name`, `symbol`, `description`, `image`, `twitter`, `telegram`, `website`, `discord`.

Bonding tokens themselves only store `metadataHash` immutably (no on-chain logo fields).

## Recommended indexing flow
1. Watch the four factories for launch events (addresses in `addresses.4663.json`).
2. Instant: fetch on-chain token meta after launch.
3. Bonding: parse `metadataUri` from the event; verify against `metadataHash` if desired.
4. Bonding graduation: watch migrator `Graduated` (V3 pool address vs V4 `bytes32 poolId`).
5. Instant soft graduation: optional poll of `graduationStatus(token)` — **not** an event.
