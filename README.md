# HAMSTER ($HAMSTER)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Parameter | Value |
| --- | --- |
| Solidity contract | `HamsterToken` (`src/HamsterToken.sol`) |
| `name()` | `HAMSTER` |
| `symbol()` | `HAMSTER` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 HAMSTER = `1000000000000000000000000000` minor units |
| Minted to | `msg.sender` of the constructor (the launch factory), once, in the constructor |
| Constructor arguments | none |
| Owner / admin | none |
| Mint after deploy | impossible: there is no mint function and no minter role |
| Transfer rules | plain ERC-20: no tax, no burn-on-transfer, no limits, no block-list, no pause |
| Extras | EIP-2612 `permit` (gasless approvals), EIP-5267 `eip712Domain()` |

## What it does

$HAMSTER is a plain token. Every transfer moves exactly the amount requested, every holder can
always transfer what they hold, and nobody can create more. The only addition to the ERC-20
standard is `permit`, which lets a holder approve a spender with an off-chain signature.

The contract is `HamsterToken`, inheriting OpenZeppelin `ERC20` and `ERC20Permit` (v5.4.0,
vendored as ordinary files under `lib/openzeppelin-contracts/`). All constants are public:
`NAME`, `SYMBOL`, `DECIMALS`, `TOTAL_SUPPLY`.

## Layout

```
foundry.toml                      solc 0.8.26, cancun, optimizer 200 runs, bytecode_hash = "none"
remappings.txt                    forge-std/ and @openzeppelin/contracts/
src/HamsterToken.sol              the token
script/DeployHamsterToken.s.sol   reference deployment (local / review use only)
test/HamsterToken.t.sol           34 tests: success, failure and fuzz
lib/forge-std                     forge-std v1.11.0 (vendored, plain files)
lib/openzeppelin-contracts        OpenZeppelin Contracts v5.4.0, only the ERC20 + ERC20Permit closure
```

## Build and test

```
forge build
forge test
forge fmt --check
```

The tests read no environment variables and do not depend on which address calls them, so they
pass in any order and in parallel. Fuzz tests were run with the verifier's seed
(`FOUNDRY_FUZZ_SEED=0x4e9f18f66037443fbc18cbec56120d676ceec891cc19459188f10375505cf202`) and with
the default random seed.

Test coverage, in brief:

- metadata, exact supply, single mint `Transfer` event from the zero address to the deployer;
- `transfer`: exact amounts, zero amounts, whole balance, self transfer, multi-hop chains that
  arrive whole; reverts on insufficient balance and on the zero-address receiver;
- `approve` / `transferFrom`: allowance accounting, infinite allowance not decremented; reverts
  beyond allowance, without approval, when the owner lacks balance, and on a zero spender;
- `permit`: sets allowance and bumps the nonce, is relayable by anyone, then `transferFrom`
  works; reverts when expired, when signed by the wrong key, on replay, and on another chain id;
  `eip712Domain()` matches;
- no privileged powers: 22 common admin selectors (mint, setMinter, upgradeTo, pause, blacklist,
  freeze, seize, burnFrom, ...) all revert from a stranger and from the deployer, supply and
  holder balances are untouched, `owner()` and `burn()` do not exist, ether is rejected;
- bytecode: runtime under the EIP-170 limit with no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`;
  the raw creation code deploys with no arguments and mints to the creator;
- fuzz: transfers conserve supply and are exact, over-balance transfers revert with the exact
  error, `transferFrom` respects any allowance, `permit` works for any value and deadline.

## Deployment

The IdentityMD launch deploys `HamsterToken` from its built creation code through the launch
factory (`ProjectFactory.launchCustom`). Nothing here deploys, broadcasts or signs, and no
`launch.json` is written here: the manifest step writes it after this work is accepted.

Launch parameters (decided by the launch, not open questions):

- Chain: Ethereum mainnet, chain id 1.
- Pool pair: IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals).
- Pool fee 12500 (1.25%), tick spacing 60, initial price `79228162514264337593543950336`
  (the deployer derives the real opening price from the market cap).
- Economics, copied verbatim by the manifest step:
  `{"poolBps":1500,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0x3ed212257958724579f13b3dba74a07ac6007903"}`.

What the factory does with the supply once it holds it:

| Share | Destination |
| --- | --- |
| 10% | the launch's MerkleDistributor (2% contributors, 8% paired seats) |
| 15% (`poolBps` 1500) | single-sided Uniswap v4 liquidity, opened at a 2,500 IMD market cap |
| 75% | `remainderTo`, `0x3ed212257958724579f13b3dba74a07ac6007903` |

Because the token has no transfer rules, none of these flows can arrive short, and no exemption
list is needed: the constructor takes neither the factory, the pool manager nor the launch number.

Manifest facts for the manifest step: `token.contract` is `HamsterToken`, `name` and `symbol`
are `HAMSTER`, `decimals` is 18, `constructorArgs` is empty, `totalSupply` is
`1000000000000000000000000000`.

### Reference script

`script/DeployHamsterToken.s.sol` exists so the deployment is reviewable and testable, not for
the launch. `deploy()` creates the token (the test calls it directly); `run()` wraps it in a
broadcast, and the broadcaster receives the whole supply. It reads nothing from the environment.

## After launch

Nothing to configure. The token has no owner, no setters and no outside dependencies. There is
no step the requester must perform for the token to work.

## Assumptions

- The requester wants a plain memecoin-style token: the brief gives a name, symbol and supply
  and asks for nothing else ($HAMSTER). No tax, burn, vesting, reflection or governance was
  requested, so none was added.
- 18 decimals, as the brief states, and a supply of exactly 1,000,000,000 whole tokens.
- The deployer of the constructor is the launch factory, which receives the whole supply. If the
  token is ever deployed by hand (the reference script), the broadcaster receives it instead.
- `permit` was added as a standard convenience with no effect on balances or supply. It is the
  only non-trivial code path beyond OpenZeppelin's ERC20 and comes from OpenZeppelin unchanged.
- Compiled with solc 0.8.26, EVM version cancun, optimizer on at 200 runs, `via_ir` off,
  `bytecode_hash = "none"` so the deployed bytes are reproducible without a metadata hash.

## Operational responsibilities

- **Nobody controls the token.** There is no owner, pause, block-list, mint or upgrade. The
  requester, IdentityMD and the factory have exactly the same powers as any holder: none beyond
  their own balance. This is deliberate and cannot be changed after deployment; a different token
  would have to be launched.
- **Holders** are responsible for their own keys and for the spenders they approve, by
  transaction or by `permit` signature. A `permit` signature is only valid until its deadline,
  for one nonce, on chain id 1, and only for this contract's address, but anyone holding a valid
  signed message can submit it, so holders should treat signed permits like signed approvals.
- **The requester** receives 75% of the supply at `remainderTo` and is responsible for that
  wallet. The launch's pool and distributor flows are the factory's, as above.
- **Source verification on the block explorer** after launch is the network deployer's step
  (`forge verify-contract` with the settings in `foundry.toml`); this job holds no keys and
  did not deploy anything.
- **Supply accounting**: `totalSupply()` can only ever fall (tokens sent to an unrecoverable
  address are still counted; there is no burn function, so it in fact never changes).

## Security notes

Checked against the eth-security checklist supplied with the task. Items that apply to a plain
token:

- Access control: there are no privileged functions, so nothing to restrict. Tested from both a
  stranger and the deployer.
- Reentrancy: the token makes no external calls (no hooks, no callbacks), so there is no
  reentrant path.
- Input validation: zero-address receiver, sender and spender all revert via OpenZeppelin's
  ERC-6093 errors; zero amounts are allowed, as the ERC-20 standard requires.
- Events: every balance and allowance change emits `Transfer` or `Approval`.
- EIP-712 replay safety: `permit` enforces nonce, deadline, chain id and verifying contract;
  all four are tested.
- No `delegatecall`, `selfdestruct`, proxy or upgrade path; all library code is internal and the
  bytecode has no link placeholders.
- Tools run: `forge build`, `forge test` (including fuzzing with the verifier's seed) and
  `forge fmt --check`. Slither and Mythril were not available in this environment and did not
  run.

Tests passing are not an audit. A separate adversarial review by an independent contributor is
still the right step before any contract that holds other people's funds goes live; this token
holds none.
