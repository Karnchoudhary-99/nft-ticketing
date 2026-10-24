# NFT Ticketing Platform

Event tickets as NFTs: mint, transfer with organizer controls, and
fraud-resistant redemption at the door — no duplicate entry, no
counterfeit tickets. Built with Foundry (Solidity 0.8.24), no external
contract dependencies (a minimal ERC-721 core lives in the contract).

## Roadmap

- [x] Project scaffold (Foundry, README, CI)
- [x] Event + ticket contracts (mint, pricing, supply caps)
- [x] Transfer controls (organizer allowlist, transfer pause, resale price cap)
- [x] Redemption (single-use check-in, anti-replay)
- [ ] Invariant fuzz tests + gas report, then self-review checklist, then public

## Quick start

```bash
forge build
forge test
```

## Contracts

| Contract | Role |
|---|---|
| `src/NftTicketing.sol` | Hosts many events: creation, primary sale, ERC-721 transfers, capped resale, single-use redemption |

Key entry points:

| Function | Who | What |
|---|---|---|
| `createEvent(name, venue, date, price, maxSupply, resaleCap, baseURI)` | anyone (becomes organizer) | Creates an event; date must be in the future, supply > 0. `resaleCap = 0` disables resale |
| `buyTicket(eventId)` (payable) | buyer | Mints one ticket for exactly `price`; reverts when sold out or after the event date |
| `transferFrom(from, to, tokenId)` | owner / approved | ERC-721 transfer, blocked when transfers are paused, the recipient is not allowlisted, or the ticket is redeemed |
| `setTransfersEnabled / setAllowlistEnabled / setAllowlisted` | organizer | Pause transfers, gate recipients to an allowlist |
| `setChecker(eventId, checker, allowed)` | organizer | Appoint door checkers (organizer is a checker by default) |
| `setResaleCap(eventId, cap)` | organizer | Change the resale ceiling (0 disables resale) |
| `withdrawProceeds(eventId)` | organizer | Withdraws accumulated primary-sale ETH for the event (resale ETH goes straight to the seller, never through the contract) |
| `listForResale(tokenId, price)` | ticket owner | Lists at a price at or under the cap; redeemed tickets cannot list |
| `buyResale(tokenId)` (payable) | buyer | Buys a listed ticket for exactly the listing price; seller is paid on-chain. This is the organizer-approved resale channel, so it works even when direct transfers are paused. The cap is re-checked at purchase time, so a listing created before a cap cut cannot sell above the new cap until it is cancelled and relisted |
| `redeem(tokenId)` | checker | Marks a ticket used exactly once; a redeemed ticket can never transfer or list again |

Anti-fraud properties: a ticket is minted only by paying the contract,
its owner is on-chain, redemption is single-use and checker-gated, and
resale prices are capped by the contract itself — not by marketplace
goodwill. Primary-sale revenue is not locked in the contract: the
organizer withdraws it per event with `withdrawProceeds`, and the
contract's balance always equals the sum of unwithdrawn proceeds
(verified by the invariant suite).

## Local demo on Anvil

```bash
anvil &
forge script script/Deploy.s.sol --broadcast --rpc-url http://127.0.0.1:8545
```

```bash
# 1. Create an event (organizer = your Anvil account 0; price 0.1 ETH,
#    100 tickets, resale capped at 0.15 ETH)
cast send <TICKETING> "createEvent(string,string,uint256,uint256,uint256,uint256,string)" \
  "Solana Nights" "Jaipur Arena" <DATE_UNIX> 100000000000000000 100 150000000000000000 "ipfs://tickets/" \
  --rpc-url http://127.0.0.1:8545 --private-key <ORGANIZER_KEY>

# 2. Buy ticket #1 (buyer = Anvil account 1)
cast send <TICKETING> "buyTicket(uint256)" 1 --value 0.1ether \
  --rpc-url http://127.0.0.1:8545 --private-key <BUYER_KEY>

# 3. List it for resale at the cap, then a second buyer takes it
cast send <TICKETING> "listForResale(uint256,uint256)" 1 150000000000000000 \
  --rpc-url http://127.0.0.1:8545 --private-key <BUYER_KEY>
cast send <TICKETING> "buyResale(uint256)" 1 --value 0.15ether \
  --rpc-url http://127.0.0.1:8545 --private-key <BUYER2_KEY>

# 4. At the door, the organizer redeems it — a second redeem reverts
cast send <TICKETING> "redeem(uint256)" 1 \
  --rpc-url http://127.0.0.1:8545 --private-key <ORGANIZER_KEY>
```

## Tests

16 Foundry tests cover events, exact-price sale, sold-out, ERC-721
transfers and approvals, transfer pause, allowlist, capped resale
(including the disabled-cap case), and single-use redemption.
Gas baseline: `.gas-snapshot`.

## License

MIT
