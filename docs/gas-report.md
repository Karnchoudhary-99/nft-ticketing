# Gas report

Baseline: `forge snapshot` (optimizer on, 200 runs, solc 0.8.24).
Figures below are full **test-scenario** gas from `.gas-snapshot` — each
scenario includes contract deployment and setup, so they are upper
bounds on the individual calls, not isolated call costs. They are useful
for spotting regressions run to run, not for quoting a user a mint price.

## Contract size

| Contract | Runtime size | Initcode size | Runtime margin to the 24,576-byte limit |
|---|---|---|---|
| `NftTicketing` | 9,517 B | 9,554 B | 15,059 B |

No external dependencies — the minimal ERC-721 core is in-contract, so
deployment stays small despite hosting many events in one contract.

## Test-scenario gas (from `.gas-snapshot`)

| Scenario | Gas |
|---|---|
| Create event + field checks | 249,097 |
| Buy ticket (mint + tokenURI) | 380,660 |
| Transfer + approval | 393,674 |
| Resale: list, buy, seller paid | 397,409 |
| Redeem once (checker) | 429,997 |
| Withdraw primary-sale proceeds (2 tickets) | 451,418 |
| Withdraw: per-event, empty/stranger rejects | 717,796 |
| Stale listing blocked after cap cut + relist | 455,027 |
| Redeemed listed ticket: sale blocked, cancel works | 442,871 |

The two withdraw scenarios are the heaviest because they mint multiple
tickets and, in the second case, run several reverting calls first.
Nothing in the happy path is close to a block gas limit.

## Invariant fuzz coverage

`forge test` invariant suite (profile `invariant`: 256 runs, depth 100,
`fail_on_revert = true`):

- 5 invariants, 25,600 calls each, **0 reverts**
- Invariants: minted ≤ supply per event; total minted == tokens issued;
  contract balance == unwithdrawn primary-sale proceeds; listings within
  the current cap; tokens belong to real events, redeemed ≤ minted.

## How to regenerate

```bash
forge snapshot   # updates .gas-snapshot
forge test       # unit + invariant suites
```
