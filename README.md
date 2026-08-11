# Peeps Launchpad (Robinhood Chain)

Public contract reference for [peeps.wtf](https://peeps.wtf) on **Robinhood Chain mainnet (`4663`)**.

This repo is for **integrators / indexers / verifiers** (Axiom, explorers, routers): addresses, ABIs, launch events, metadata rules, and Solidity sources for Peeps Instant + Bonding products.

**Not included:** the peeps.wtf web app, APIs, indexers, or infra.

---

## Products

| Product | DEX | Launch style |
|---------|-----|--------------|
| **Instant V3** | Uniswap V3 | Live locked pool from block 0 |
| **Instant V4** (Tax) | Uniswap V4 | Live pool + tax hook from block 0 |
| **Bonding → V3** | Curve → Uni V3 | Bonding curve, then migrate |
| **Bonding → V4** (Tax) | Curve → Uni V4 | Bonding curve, then migrate |

**Narrative** on peeps.wtf is UI-only: it prefills a Tax Instant or Tax Bonding form. Same factories — no separate Narrative contracts.

---

## Quick start for indexers

1. Read [`addresses.4663.json`](./addresses.4663.json)
2. Read [`METADATA.md`](./METADATA.md) — where name / ticker / image live
3. Watch factory launch events in [`events/events.json`](./events/events.json)
4. Decode with ABIs under [`abis/`](./abis/)

### Singleton factories to watch

| Product | Address | Launch event |
|---------|---------|--------------|
| Instant V3 | `0xeE6D48e781c1bA547B63a3d65Db87F67305D1531` | `TokenLaunched` |
| Instant V4 | `0x60796114CF6Ac0759098788e6d4D1F4774556A34` | `V4TokenLaunched` |
| Bonding V3 | `0x84A9Ac2A545B72efed12CD8E8EaB647Af0e3f303` | `TokenCreated` |
| Bonding V4 | `0xEEb8Ac11e9E70AFb9979204fbD9A0166Ecc28BC9` | `TokenCreated` |

### Metadata (important)

| Product | Name / ticker on factory event? | Image / socials |
|---------|----------------------------------|-----------------|
| Instant V3 / V4 | **No** — call `name()` / `symbol()` on the token | On-chain: `logo()`, `description()`, `socials()` |
| Bonding V3 / V4 | **Yes** on `TokenCreated` | Off-chain: `metadataUri` + `metadataHash` on the event |

Full detail: [`METADATA.md`](./METADATA.md).

---

## Repo layout

```
addresses.4663.json      # Live addresses (RH 4663)
deployments.4663.json    # Raw Peeps deployment manifest
events/events.json       # Launch / graduation / trade events + topic0
METADATA.md              # Metadata storage rules
abis/
  instant-v3/            # Factory, locker
  instant-v4/            # Factory, registry, swap, hook, vault, …
  bonding-v3/            # Factory, router, migrator, vault, token
  bonding-v4/            # Factory, router, migrator, tax store, token
  shared/                # Bonding curve, fee sink, aggregator, …
  token-metadata/        # PeepsToken + PeepsV4Token (logo/socials)
contracts/
  instant/               # Solidity sources
  v4/
  bonding-v3/
  bonding-v4/
  legacy-curve/          # Shared bonding curve + interfaces
```

---

## Lockers / LP custody (high level)

- **Instant V3 locker:** `0x9d6CDEe7243002bBDe5C1AB7bc664542ae153c93` (`PeepsLocker` — Uni V3 NFT)
- **Instant V4:** LP fee vault + dividend distributor (see `addresses.4663.json` → `instantV4`)
- **Bonding V3:** post-grad LP fee vault
- **Bonding V4:** graduate Instant-V4-style vault / dividend stack (`bondingV4.graduate*`)

Do not confuse Instant V4 **create** factory `0x6079…` with Bonding→V4 **graduate** Instant factory `0xF68f…`.

---

## Shared Uni infra (RH)

- WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- Uni V3 factory / NPM / SwapRouter02 / Quoter — in `addresses.4663.json` → `shared`
- Uni V4 PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`

---

## License

Solidity and ABIs are provided for integration and verification. See [`LICENSE`](./LICENSE).

## Links

- App: https://peeps.wtf  
- This repo: https://github.com/Toomicky/peeps-launchpad
