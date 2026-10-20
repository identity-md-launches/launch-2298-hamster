# HAMSTER test coverage

The existing `HamsterToken.t.sol` suite is preserved. The additional suites use the
repository's vendored dependencies and require no network, fork, FFI, credentials,
or environment mutation.

- `HamsterTokenEdges.t.sol`: zero, one minor unit, full supply, maximum integers,
  approval replacement and revocation, delegated self-transfers, failed-call
  rollback, transfer round trips, and split-versus-single delegated transfers.
- `HamsterPermit.t.sol`: independently constructed EIP-712 domains, exact deadline
  boundaries, changed signed fields, invalid and malleable signatures, wrong
  signers, cross-token and cross-chain rejection, sequential nonces, replay after
  spending, and interaction between permits and ordinary approvals.
- `HamsterInvariant.t.sol` and `handlers/HamsterHandler.sol`: four funded actors
  execute transfers, approvals, delegated spending, permits, invalid operations,
  replay attempts, and time advances in random order. Four invariants check the
  fixed supply and aggregate balance, each actor's balance, every actor-to-actor
  allowance, and each actor's permit nonce.

The invariant model starts from the specified supply and updates from successful
operation inputs. It does not copy token getters into the expected state. Expected
failures assert their revert reasons and leave the model unchanged. An unexpected
handler revert fails the campaign. A deterministic test also exercises every
handler action, including positive transfers and all invalid-permit modes.

The new stateless properties run 1,000 cases each. The invariant campaign runs 256
sequences of 96 calls, checking all four invariants after each action. These
settings are inline in the test files.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4e9f18f66037443fbc18cbec56120d676ceec891cc19459188f10375505cf202 forge test
```

Coverage limits: the invariant state space is deliberately closed to four actors,
so its balance sum accounts for every recipient it can reach. The existing
stateless transfer fuzz test additionally covers arbitrary nonzero recipients.
These local tests exercise the standalone token. The supplied protected factory,
ownership, pool initialization, and swap checks depend on launch infrastructure
and configuration outside this checkout and are not executed by this local suite.
No production system is contacted. Passing these tests is not proof that all
possible call sequences or launch integrations are correct.
