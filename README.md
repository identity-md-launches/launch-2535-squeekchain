# squeekchain (SQK)

A fixed-supply ERC-20 token. The constructor mints the entire supply once to its
immediate deployer. The implementation is in `src/Squeekchain.sol` and uses the
vendored OpenZeppelin ERC-20 without modifying its transfer or approval logic.

## Token and deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract | `Squeekchain` |
| Fully qualified artifact | `src/Squeekchain.sol:Squeekchain` |
| Name | `squeekchain` |
| Symbol | `SQK` |
| Decimals | `18` |
| Supply in whole tokens | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Supply constant | `INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18` |
| Constructor arguments | None; argument list `[]` |
| Deployment value | `0` ETH; constructor is nonpayable |
| Initial recipient | Constructor `msg.sender`, the immediate deployer |
| Intended launch chain | Ethereum, chain ID `1` |
| Owner / administrator | None |
| Post-deployment initialization | None |

For the supplied factory launch, the factory receives **100% of the supply**.
The transaction sender does not receive tokens merely because it called the
factory. The token's constructor has no external calls, allocates no tokens
elsewhere, and needs no factory address, owner address, oracle, or other setting.

The launch system is responsible for deploying the creation bytecode, preparing
the manifest, distributing the supply, and setting up liquidity. Under the
supplied launch terms, the factory distributes 10% through the swarm distributor,
40% to the pool, and the remaining 50% to the requester. Those transfers happen
after construction and are not special rules or privileges in this token.
Only `Squeekchain` is a production contract; fixtures in `test/` are not launch
contracts. This repository does not create a launch manifest or broadcast a
transaction.

## Behavior and assumptions

- Standard `transfer`, `approve`, `transferFrom`, `balanceOf`, `allowance`, and
  metadata functions. Successful token operations return `true`; invalid ones
  revert with OpenZeppelin's ERC-6093 custom errors.
- No transfer fees, taxes, rebasing, supply growth, or public burn function.
  Supply stays exactly `10^27` base units throughout the deployed token's life.
- No ownership, mint authority, pause, blacklist, confiscation, upgrade,
  initialization, or recovery functions. The deployer has the same rights as any
  other holder after construction.
- Zero-value transfers between valid addresses are allowed and emit `Transfer`.
  Self-transfers preserve the balance. Transfers to the zero address and approvals
  to the zero spender revert.
- Finite allowances decrease on `transferFrom`, including transfers back to the
  holder. An allowance of `type(uint256).max` remains unchanged when spent.
  `approve` replaces the previous allowance, including revocation with zero.
- `approve` emits `Approval`; construction and transfers emit `Transfer`.
  This OpenZeppelin implementation does not emit `Approval` when `transferFrom`
  spends an allowance. Integrations should query `allowance` for current values.
- Transfers perform no external calls or recipient callbacks, and ordinary
  contracts can receive tokens without implementing a receiver interface.

## Build and check

Run from the repository root with Foundry and Solidity `0.8.26` available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x26fcf6002fb4e576fee27c6c7554dc346e15a61353f4c51579f175157e622da2 forge test
forge fmt --check
```

`foundry.toml` pins Solidity `0.8.26`, the Cancun EVM target, optimizer enabled
with 200 runs, and `bytecode_hash = "none"`. It enables neither FFI nor filesystem
permissions. All Solidity dependencies and their licenses are ordinary files in
`lib/`; no install command, Git submodule, environment file, RPC connection, or
network access is needed to build or test once the compiler is installed.
Tests do not read or change environment variables. The seed above configures the
Foundry runner, and the configuration does not override it.

For the downstream deployer, these read-only commands expose the deployable
artifact and ABI:

```sh
forge inspect src/Squeekchain.sol:Squeekchain bytecode
forge inspect src/Squeekchain.sol:Squeekchain abi
```

Deploy the creation bytecode directly with no appended constructor arguments and
no value. The contract has no external library link references and needs no proxy
or initialization transaction. Use the pinned build configuration when verifying
the deployed source.

## Tests and review

- `test/Squeekchain.t.sol`: metadata, exact supply, the single constructor mint
  event, full and zero transfers, self-transfers, events, finite and infinite
  allowances, allowance replacement and revocation, unauthorized spending,
  invalid addresses, insufficient funds/allowances, and atomic rollback.
  It also checks that attempted mint, burn, and administrative calls fail from
  both the deployer and an unrelated account.
- `test/SqueekchainLaunch.t.sol`: CREATE2 deployment through a local factory,
  exact distribution and claim transfers, and transfers into and out of a pool
  accounting fixture. This checks the token's transfer behavior; it does not
  simulate a Uniswap pool or run the separate protected launch harness.
- `test/SqueekchainInvariant.t.sol`: randomized transfer, approval, and delegated
  transfer sequences among four holders, compared with an independent balance
  and allowance model. Each sequence preserves the full supply. Unexpected
  handler reverts fail the invariant test.

Local validation passed all 27 tests with the seed above: six fuzz tests at 1,000
cases each, plus 256 invariant sequences of depth 64 (16,384 calls, zero reverts).
`forge build` and `forge fmt --check` also passed.

Manual review covered constructor allocation, supply-changing entry points,
spender authorization, revert atomicity, and external-call/upgrade surfaces.
Only the constructor reaches the internal mint function; no runtime entry point
exposes minting or burning. The token has no external calls, delegatecalls, price
calculations, signature validation, or administrative roles. Slither and Mythril
were not run. The separate launch admission tests and independent review remain
the launch process's responsibility.

## After launch

There are no setters or ongoing token administration tasks. The launch operator
must verify the deployed artifact and metadata, confirm the initial factory
allocation and subsequent distribution, and publish the token's actual address
and verified source. Liquidity and distributor operation belong to the external
launch system.

Holders manage their own custody, recipient addresses, and spending approvals.
Use allowances appropriate to the intended spend and revoke unnecessary ones.
When replacing an existing nonzero allowance, clients should first set it to zero
and wait for confirmation to reduce the standard ERC-20 approval-change race.
Unlimited approval authorizes the spender to spend future deposits too.

There is no administrator to reverse transfers, restore lost keys, pause an
incident, upgrade the code, or recover assets sent to the token contract itself.
Native ETH transfers are not accepted through a payable function. Tokens or
forcibly delivered ETH at the token's address have no withdrawal path.

## Vendored dependencies

- [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/dbb6104ce834628e473d2173bbc9d47f81a9eec3),
  commit `dbb6104ce834628e473d2173bbc9d47f81a9eec3`: the five unmodified Solidity
  files required by ERC-20, plus the [MIT license](lib/openzeppelin-contracts/LICENSE).
- [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505),
  commit `77041d2ce690e692d6e03cc812b57d1ddaa4d505`: upstream `src/` and its
  [MIT](lib/forge-std/LICENSE-MIT) and [Apache-2.0](lib/forge-std/LICENSE-APACHE)
  licenses; used only by tests.

`DEPENDENCIES.lock.json` records upstream commits, archive SHA-256 hashes, and
SHA-256 hashes of every vendored file. It is provenance data, not a build-time
download mechanism.
