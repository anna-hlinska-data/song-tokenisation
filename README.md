# Song Tokenisation

A Solidity smart contract for fractional ownership of songs, plus a notebook exploring
live Bitcoin blockchain data. Built for the DAS5003 Blockchain Fundamentals module.

## Smart contract — `SongTokenisation.sol`

Each song is split into a fixed number of shares. Fans buy shares with ETH, the payment
goes straight to the song's rights holder, and ownership is tracked on-chain.

**Features**

- `createSong` — owner registers a song with title, artist, total shares, price per share
  and rights-holder address; all shares start with the rights holder
- `buySongShares` — buy shares for the exact ETH amount; payment is forwarded to the
  rights holder
- `transferSongShares` — move shares between addresses
- `sellSongShares` — sell shares back at the original price, paid from the contract
  balance (topped up by the owner via `fundContract`)
- `deactivateSong` — owner can stop trading for a song
- Events for every state change (`SongCreated`, `SongSharesPurchased`, `SongSharesTransferred`,
  `SongSharesSold`, `SongDeactivated`)

**Analytics (view functions)**

- `getTotalAssetsCreated` — number of tokenised songs
- `getAssetOwners` — current holders of a song and their share counts
- `getTop10Beneficiaries` — top 10 holders with ownership percentage (2-decimal precision,
  e.g. `5000` = 50.00%)
- `getSongDetails`, `getSharesOwned`, `getAllSongs`, `getContractBalance`

`getSongDetails` returns a `SongDetails` struct instead of eight separate values to avoid the
EVM "Stack too deep" compiler error.

**Running**

Open the contract in [Remix IDE](https://remix.ethereum.org), compile with Solidity `^0.8.0`
and deploy to the Remix VM or a testnet. The deploying account becomes the owner.

**Known limitations**

- Top-10 ranking uses an in-memory bubble sort over all holders — fine for small holder
  lists, but gas cost grows quadratically.
- Payouts use `transfer`, which forwards a fixed 2300 gas and can fail for contract
  recipients; `call` with a reentrancy guard would be more robust.
- `sellSongShares` does not check whether the song is still active.

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

## Author

**Anna Hlinska** — [github.com/anna-hlinska-data](https://github.com/anna-hlinska-data)
