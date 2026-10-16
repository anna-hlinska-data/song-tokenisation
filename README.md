# Song Tokenisation

A Solidity smart contract for fractional ownership of songs, tested with Foundry, plus a
notebook exploring live Bitcoin blockchain data. Built for the DAS5003 Blockchain
Fundamentals module.

## Smart contract — `src/SongTokenisation.sol`

Each song is split into a fixed number of shares. Fans buy shares with ETH, can transfer
them to others, and can sell them back while the song is active.

### How money flows

```
fan ──buy──▶ shares from buy-back pool first ──▶ ETH refills the song's buy-back reserve
         └─▶ remaining shares from rights holder ─▶ ETH credited to rights holder (withdraw())

fan ──sell─▶ shares go to the buy-back pool ◀── ETH paid from the song's buy-back reserve
                                                 (funded by the owner via fundBuyback())
```

- **Primary sales** are credited to the rights holder and collected with `withdraw()`
  (pull payments), so a smart-contract wallet such as a multisig can be a rights holder.
- **Buy-back** is backed by a per-song reserve that the owner funds and can withdraw.
  Bought-back shares sit in a contract-held pool and are resold first; their proceeds go
  back into the reserve, so the same shares are never paid to the rights holder twice.
- **Accounting invariant:** the contract balance always equals the sum of buy-back
  reserves plus pending withdrawals.

### Functions

| Function | Who | Purpose |
|---|---|---|
| `createSong` | owner | Register a song; all shares start with the rights holder |
| `buySongShares` | anyone | Buy shares for exactly `price × amount` |
| `transferSongShares` | holder | Move shares to another address |
| `sellSongShares` | holder (not rights holder) | Sell shares back from the reserve |
| `withdraw` | rights holder | Collect earnings from primary sales |
| `fundBuyback` / `withdrawBuybackReserve` | owner | Manage a song's buy-back reserve |
| `deactivateSong` | owner | Stop buying and selling for a song |
| `transferOwnership` | owner | Hand over contract ownership |

**Analytics:** `getTotalAssetsCreated`, `getAssetOwners`, `getTop10Beneficiaries`
(ownership in basis points, `5000` = 50.00%), `getSongDetails`, `getSharesOwned`,
`getAllSongs`, `getContractBalance`.

## Security review

The first version of the contract (kept in `test/legacy/` for reference) had four issues.
Each one is reproduced by a proof-of-concept test against V1 and covered by a regression
test against the current version.

| Issue in V1 | Impact | Fix |
|---|---|---|
| Rights holder could call `sellSongShares`; shares moved from them back to themselves | **Critical:** rights holder drains the whole contract balance without losing shares | Rights holder can't sell back; bought-back shares go to a contract pool |
| Bought-back shares returned to the rights holder and could be resold | Each buy/sell round trip moved funder money to the rights holder | Pool shares are sold first and refill the reserve; reserve is per song |
| Payments used `transfer` (2300 gas) | Purchases always revert if the rights holder is a smart-contract wallet | Pull payments with `call` and a reentrancy guard |
| `sellSongShares` ignored `active` | Trading continued after a song was deactivated | `active` check on sell |

Also added: `indexed` event parameters, `transferOwnership`, withdrawal of unused reserve,
a pinned compiler version, and an O(10·n) top-10 selection instead of a full O(n²) sort.

## Tests

```bash
forge install   # fetches forge-std
forge test
```

| Suite | What it checks |
|---|---|
| `test/SongTokenisation.t.sol` | Unit tests for every function, regression tests for the V1 issues, reentrancy, fuzz tests for round trips and share conservation |
| `test/Invariant.t.sol` | Random sequences of buy / sell / transfer / fund / withdraw (1,000 runs × 500 calls): balance always matches accounting, total shares always conserved |
| `test/legacy/ExploitV1.t.sol` | Proof-of-concept exploits against the original contract (these pass, showing the attacks work on V1) |

32 tests pass; line coverage of `SongTokenisation.sol` is 98.6%.

### Known limitations

- `getAssetOwners`, `getTop10Beneficiaries` and `getAllSongs` loop over all holders /
  songs. They are view functions, but very large lists can still exceed RPC gas limits;
  an indexer (e.g. The Graph) reading the events would be the production approach.
- Shares are tracked in plain mappings rather than a token standard; ERC-1155 would make
  them visible in wallets and tradable on marketplaces.

## Notebook — `blockchain_data_analysis.ipynb`

Queries the public [blockchain.info](https://www.blockchain.com/explorer/api) API (no API key
needed) to answer:

1. Latest block height and network difficulty
2. Miner address of the latest block (from the coinbase transaction) and whether its owner
   can be identified
3. Number of transactions in the block
4. Address with the highest balance in a sample of the block's transactions
5. Most active address in the sample
6. First transaction date of that address
7. How to retrieve all Bitcoin blockchain data up to 1 January 2020

Results reflect the chain state at the time of analysis (7 December 2025, block 926,904).

```bash
pip install requests jupyter
jupyter notebook blockchain_data_analysis.ipynb
```

## Project structure

```
src/SongTokenisation.sol          contract
test/SongTokenisation.t.sol       unit, regression and fuzz tests
test/Invariant.t.sol              invariant tests
test/legacy/                      original V1 contract and exploit PoCs
blockchain_data_analysis.ipynb    Bitcoin data analysis
```

## Author

**Anna Hlinska** — [github.com/anna-hlinska-data](https://github.com/anna-hlinska-data)
