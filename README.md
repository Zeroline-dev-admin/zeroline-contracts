# ZEROLINE

**Free trading cups on BNB Smart Chain. Every player starts with the same 10,000 points.**

Website: https://zeroline.gg · X: https://x.com/zeroline_gg · Telegram: https://t.me/zeroline_gg

ZEROLINE runs short trading contests ("cups") on real market prices. Everyone starts with 10,000 points, so the ranking shows who traded well, not who had the most money. Points, not money: joining is free and no deposit is needed. Top players claim USDT prizes put up in advance by the cup's host.

This repository holds the smart contracts behind ZEROLINE and their BNB Smart Chain mainnet addresses.

## How it uses BNB Smart Chain

1. **A cup cannot exist without its prize.** `CookedFactory` creates each cup and moves the host's full USDT prize pool into that cup's `ContestPrizes` contract in the same transaction.
2. **Orders are sealed.** A player's order is committed to `ContestBook` as a hash. Other players see the rank, never the trades. The block time and the price at the commit are recorded.
3. **Prices are recorded on chain.** The operator posts the median of public exchange prices to `PostedOracleV2`. Each post is an event with its block time, so anyone can compare it with the exchanges' public 1-minute candles. `ContestPrices` records a checkpoint for each slot.
4. **Players send their own orders.** With `postSignedAndCall`, an order leaves from the player's own address and fills at a fresh operator-signed price. Gas is sponsored through NodeReal MegaFuel, so players need no BNB.
5. **Results anyone can check.** After the bell every order is revealed and must match its hash. The final ranking is posted on chain, and winners claim USDT from `ContestPrizes` with a Merkle proof from their own wallet.

## Contracts

| Contract | Role |
|---|---|
| `CookedFactory` | Creates each cup (three minimal clones) and locks the host's prize pool |
| `ContestBook` | Sealed orders: commit a hash, reveal after the bell |
| `ContestPrices` | Price checkpoints for the cup's coins, at most one per slot |
| `ContestPrizes` | Holds the prize pool, takes the posted result, pays claims |
| `PostedOracleV2` | Operator-posted prices, plus `postSignedAndCall` for player-sent orders |
| `PostedOracle` | Earlier version of the price input (cups #1 to #5) |
| `CookedEntry` | Entry conditions: passes and principal-protected deposits |
| `CookedFees` | Entry-fee cups |
| `PythOracle`, `PriceRelay` | Pyth price input (not used on BNB mainnet today) |
| `TestUSDC`, `contracts/test/*` | Testnet and test-only tokens and mocks |

## BNB Smart Chain mainnet (chain id 56)

Cups #6 and later:

| Contract | Address |
|---|---|
| CookedFactory | [`0x11b123b02A212d9A2177761a099D6050d9258971`](https://bscscan.com/address/0x11b123b02A212d9A2177761a099D6050d9258971) |
| PostedOracleV2 | [`0x4bf0aE170AbCaB4C689143E3Ef68875f911CAFDD`](https://bscscan.com/address/0x4bf0aE170AbCaB4C689143E3Ef68875f911CAFDD) |
| ContestPrices (implementation) | [`0x6A21F4816F6e01D3E820874B547E17553c874Ace`](https://bscscan.com/address/0x6A21F4816F6e01D3E820874B547E17553c874Ace) |
| ContestBook (implementation) | [`0x98483449BA40aed849bbF57a326b940E5F0Da32F`](https://bscscan.com/address/0x98483449BA40aed849bbF57a326b940E5F0Da32F) |
| ContestPrizes (implementation) | [`0x701C6B6fDEE7c658d22c2634288657C6F8a5c3D8`](https://bscscan.com/address/0x701C6B6fDEE7c658d22c2634288657C6F8a5c3D8) |
| CookedEntry | [`0x40f9E0A675e333165691411e34CfB94620A225D7`](https://bscscan.com/address/0x40f9E0A675e333165691411e34CfB94620A225D7) |
| CookedFees | [`0x7409Dab98100c6039270aaCd8ca342c6fA03d164`](https://bscscan.com/address/0x7409Dab98100c6039270aaCd8ca342c6fA03d164) |

Cups #1 to #5 (earlier factory):

| Contract | Address |
|---|---|
| CookedFactory | [`0x6C0A2fC906d86Df2aD5708941470e10960A5231E`](https://bscscan.com/address/0x6C0A2fC906d86Df2aD5708941470e10960A5231E) |
| PostedOracle | [`0x70aA27966f6Adf0d912B7a8cb03bE3B8459941bA`](https://bscscan.com/address/0x70aA27966f6Adf0d912B7a8cb03bE3B8459941bA) |
| ContestPrices (implementation) | [`0x43F17Ca87aDF8744C5869C01CAEba03Ba696F521`](https://bscscan.com/address/0x43F17Ca87aDF8744C5869C01CAEba03Ba696F521) |
| ContestBook (implementation) | [`0x96A4062932CbaF187ECFB61d6F8d089FE2f24043`](https://bscscan.com/address/0x96A4062932CbaF187ECFB61d6F8d089FE2f24043) |
| ContestPrizes (implementation) | [`0x892f7a9Fa9fC0B740A7c319c0ceEc274e24E6f78`](https://bscscan.com/address/0x892f7a9Fa9fC0B740A7c319c0ceEc274e24E6f78) |
| CookedEntry | [`0xE51f9259fac667F6283193aDDCBEec8423CBf486`](https://bscscan.com/address/0xE51f9259fac667F6283193aDDCBEec8423CBf486) |

The same list is in [`deployments/bsc-mainnet.json`](deployments/bsc-mainnet.json). Each cup's own contracts are clones created by the factory; their addresses are listed on each cup's page at zeroline.gg.

## Build

Requires Node.js 18 or later.

```bash
npm install
npx hardhat compile
```

Compiler: Solidity 0.8.24, optimizer on (1 run), EVM version cancun. Dependencies: OpenZeppelin Contracts 5.6.1.

## Tech stack

- Smart contracts: Solidity, Hardhat, OpenZeppelin
- Chain: BNB Smart Chain mainnet
- Gas sponsorship: NodeReal MegaFuel
- App: web app at zeroline.gg and a Telegram Mini App

## Status

Live on BNB Smart Chain mainnet. These contracts have not had a third-party audit yet.

## License

MIT
