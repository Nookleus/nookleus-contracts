# Nookleus contracts

Site: https://nookleus.xyz · X: https://x.com/nookleuseth · GitHub: https://github.com/Nookleus

Nookleus ($NOOK) is a living Uniswap v4 hook. It watches the other v4 hooks on Ethereum, measures which kinds of hooks
carry real trading life, and every hour may move one of its own six strands one level toward what the ecosystem
rewards. Scouts list hooks, observers keep the readings fresh, challengers catch copies, and holders share the fees.

This is the source for the Programmable Custom Launch on Ethereum mainnet, compiled with solc 0.8.26+commit.8a97fa7a,
viaIR, optimizer 1000 runs, evmVersion cancun, metadata bytecodeHash none. The repository holds exactly the files the
contracts compile, byte for byte: `forge build` here gives the same bytecode as the tested tree.

## Contracts

| File | Role |
| --- | --- |
| `src/Nook.sol` | The ERC-20, 1,000,000,000 minted once to the launch step, no mint after. Tracks each holder's holding age and shares NECTAR (ETH) with every holder pro rata. Carries the token half of the launch protection. |
| `src/Nucleus.sol` | The pool's hook (flags 0x2ACC). Takes the fees in ETH, keeps the six strands, books every fee, refuses part fills and zero-ETH trades, admits liquidity only for the launch band and ROOTS, never removes any. Carries the swap half of the launch protection. |
| `src/Helix.sol` | The brain and the clock: an hourly preview at :45, the step on the hour, a 6-hour cooldown before a dropped strand returns, daily SPORES hours, 30-day seasons, scored predictions. |
| `src/Lens.sol` | Readings of other v4 pools (fee growth and ETH depth through `extsload`), the Hall of Hooks, the paper index (positions on paper, no tokens held), the observers' bounty. |
| `src/FieldGuide.sol` | The list of hooks: a 0.002 ETH deposit per listing, each hook's DNA and family, exact and near-copy detection, the challenge that proves a copy. |
| `src/Gut.sol` | DIGEST (buys $NOOK from the pool and burns it; one sweep spends at most 1% of the ETH that would move the price 2%, at most once an hour) and ROOTS (ETH liquidity placed above the price, never removed). |
| `src/Specimens.sol` | The collectibles: Trait, Species and Almanac specimens, minted only by the contracts. |
| `src/Amber.sol` | Holds the launch band's position NFT forever. |
| `src/Sprout.sol` | The launch step, once: wires the contracts, opens the pool, seeds the band, starts trading, makes the first buy. |
| `src/Interfaces.sol` | The calls between these contracts. |
| `src/vendor/EthereumNativeFeeVaultV3.sol` | Programmable's fee vault, unmodified. The hook creates two: one for the platform fee, one for the opening surcharge. |
| `src/vendor/LaunchProtectionModuleV1.sol`, `src/vendor/ProtectedLaunchTokenV1.sol` | Programmable's launch protection module, unmodified (the token file is only its interface). The hook creates the module. |

There is no owner function, no pause, no upgrade, no proxy and no way to remove liquidity in any contract.

## Fees on every trade

The pool's LP fee is 0%: the hook refuses any other. All fees are taken in ETH by the hook, on buys and sells alike.

| Fee | Rate | Goes to |
| --- | --- | --- |
| Programmable platform fee | 0.30% of the trade's gross ETH, rounded up | `EthereumNativeFeeVaultV3`, claimable only by Programmable's treasury |
| Owner | 1.5% | The owner, paid out by `remitOwner()` (anyone may call it; the ETH goes only to the owner) |
| Module | 1% base | The ecosystem, below |

A normal trade pays 2.8%. TEMPER adds up to 0.125% per level when the price is far from its 10-minute mean; KINSHIP
takes 6.25% per level off the module fee for wallets holding at least 1,000,000 $NOOK for 7 days. Owner plus module never
exceed 3.5%, so a trade never pays more than 3.8%.

The module fee: 10% to the scout of the hook a buyer pledged in the swap's hookData, 5% to the observers, then by the
strand levels: NECTAR 7.5% per level to every holder, DIGEST 7.5% per level to buyback and burn (plus whatever no strand
claims), ROOTS 2.5% per level to liquidity above the price, SPORES 2.5% per level to a pot released to holders at random
hours. Every strand starts at level 4.

## Launch protection

Programmable's mandatory policy v1, in force from the start of trading:

- The pool opens at a fully diluted value of at least USD 15,000, checked in the launch transaction against Chainlink's
  ETH/USD feed (at most one hour old). Below it the whole launch reverts.
- For 300 seconds, every buy must come through the canonical Universal Router
  (`0xd92A36B0000531EF3063dEd4De20A0783308446C`), and no buyer may take more than 2% of the supply in total.
- For 300 seconds, no address may receive more than 2% of the supply in total. Selling, sending or burning never
  restores the allowance. Nobody is exempt.
- For 30 seconds, buys pay 99% in total, falling linearly to the normal fee. Everything above the normal fee goes to a
  separate vault only Programmable's treasury can claim. The owner and up to six named wallets skip the surcharge and
  keep both 2% limits. Sells pay normal fees throughout.
- The first buy is required, made in the launch transaction for the owner, and is itself held to 2%.

## Measured gas

| Action | Gas |
| --- | --- |
| Buy, exact ETH in | 201,673 |
| Sell, exact $NOOK in | 188,734 |
| Buy with a pledge and a prediction | 286,617 |
| Buy that runs the hourly preview | 321,884 |
| Buy on a new UTC day (SPORES hours drawn) | 258,236 |
| Buy closing a season a day overdue | 819,602 |
| `flow` (books to holders, gut, lens) | 361,137 |
| `remitOwner` | 88,324 |
| `digest` (buyback and burn) | 366,431 |
| `plant` (ROOTS) | 261,183 |
| `list` a pool of a new family | 743,532 |
| `sample` 8 pools, steady state | 696,929 |

The hourly pulse rides on a trade with at most 1,200,000 gas lent to it. If it fails, the trade still goes through and
the pulse is retried 15 minutes later.

## Build

```
forge build
```

Foundry with solc 0.8.26, settings in `foundry.toml`. The `lib/` folders hold only the Uniswap v4, Permit2 and
OpenZeppelin files these contracts import, unmodified, with their licenses.
