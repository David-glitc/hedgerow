# Sherhood

**Pool USDT. Collect your share of BOT.** The Sherhood pool and collectible protocol, adapted to USDT and wrapped BOT on BOT Chain.

**Status:** contracts are tested on a BOT Chain mainnet fork; the mainnet deployment is pending.

- Website and app: https://sherhood-botchain.davidopuene8.workers.dev (app at [`/app/`](https://sherhood-botchain.davidopuene8.workers.dev/app/))
- Network: BOT Chain mainnet, chain ID 677 · [BOT Chain](https://www.botchain.ai/) · [BOTScan](https://scan.botchain.ai/)

![Sherhood landing page](docs/sherhood-landing-1280.png)

## How it works

1. **Join a pool.** Deposit USDT into an instant solo pool or a community pool with a funding goal.
2. **Mint a Sherd.** Every deposit mints a collectible card. When the pool fills, its USDT buys WBOT on BDEX.
3. **Reveal and claim.** Block entropy reveals each card's share. Claim your WBOT or sell the card for USDT.

## Features

- **Real onchain assets.** Pools buy WBOT through the live BDEX USDT/WBOT pool.
- **Collectible cards.** Each Sherd is an NFT that carries its share of the pool until claimed.
- **Built-in market.** List or buy revealed Sherds for USDT in the card marketplace.
- **Protected principal.** Underfunded pools can be cancelled after their deadline for a full USDT refund.

## Contracts

| Contract | BOT Chain mainnet |
|---|---|
| `BotSwapAdapter` | Pending mainnet deployment |
| `BotEntropy` | Pending mainnet deployment |
| `TreasuryDirect` | Pending mainnet deployment |
| `PotCard` | Pending mainnet deployment |
| `PotFactoryV2` | Pending mainnet deployment |
| `RevealEngine` | Pending mainnet deployment |
| `AssetManager` | Pending mainnet deployment |
| `StockTokenRegistry` | Pending mainnet deployment |
| `CardMarketplace` | Pending mainnet deployment |

BOT Chain infrastructure used: USDT `0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C`, WBOT `0xD5452816194a3784dBa983426cCe7c122F4abd30`, BDEX router `0x07032d47A1b9f8460cBeE9dC17c1d3E438693929`, BDEX QuoterV2 `0x034A705b36067cff99ABf5C662Be881cBd8d0176`.

Source: [`contracts/src`](contracts/src). Tests: [`contracts/test`](contracts/test). The contracts are unaudited; use small amounts.

## Develop

Requires Node 20+, [Foundry](https://getfoundry.sh) and Python 3.

```bash
git clone --recursive https://github.com/David-glitc/sherhood-botchain.git
cd sherhood-botchain
npm ci
npm test              # forge test
npm run build         # landing page + app into dist/sherhood
npm run preview       # http://127.0.0.1:8771
```

`npm run build` writes `dist/sherhood/index.html` (landing page), `dist/sherhood/app/` (the dApp) and a Cloudflare Workers bundle under `sites/`.

### Wallets

The app discovers installed wallets with EIP-6963 (BO Wallet, MetaMask, OKX, Rabby and others) and falls back to `window.ethereum`. It switches or adds BOT Chain (chain ID `0x2a5`, RPC `https://rpc.botchain.ai`) before any transaction, and simulates every call before asking for a signature.

### Rehearse on a mainnet fork

```bash
anvil --fork-url https://rpc.botchain.ai --port 8677 --chain-id 677
export BOT_RPC_URL=http://127.0.0.1:8677
node scripts/deploy.mjs && node scripts/fork-check.mjs
```

### Deploy

`scripts/deploy.mjs` reads the deployer key from `BOT_SIGNER_FILE` (default `~/.config/botchain-wave1/deployer.env`, never committed), refuses to broadcast on mainnet without `BOT_MAX_GAS_BOT`, and journals every transaction to `deployments/mainnet.json` so it can resume. `python3 scripts/publish.py` publishes the site with a one-hour, Workers-only Cloudflare token and revokes it afterwards.

## License

MIT. Built on [BOT Chain](https://www.botchain.ai/).
