# .sqk names

`bona.sqk` is registered as the label `bona`. Each name is an ERC-721, paid for in $SQK.

## Features
- Commit-reveal registration (no front-running)
- ASCII-only labels `[a-z0-9-]`, 3–63 chars (no homoglyph spoofing, no dots)
- Tiered yearly price by length (3 / 4 / 5+ chars), 1-year minimum, 30-day grace period, anyone can renew
- Address + text records; records reset on every transfer and re-registration
- Forward-confirmed reverse lookup: `nameOf(address)`
- Two-step ownership: set `ADMIN` to the Squeekchain admin Timelock

## Setup
```
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.0.2
forge test -vv
ADMIN=0x... TREASURY=0x... forge script script/Deploy.s.sol --rpc-url sepolia --broadcast
```

## Before deploying
- Confirm `SqueekToken.decimals()` and set real prices.
- Payment is `transferFrom` to the treasury. If SqueekToken exposes a burn function you want to use, replace the transfer in `register` and `renew`.
- Sepolia only, like the rest of Squeekchain. The Squeekchain contracts are unaudited testnet deployments.
- ENS and wallets won't resolve `.sqk` on their own. Resolution happens through this contract, via your dapp or SDK.
