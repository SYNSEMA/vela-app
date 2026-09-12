# vela-app — a confidential app for Vela (Horizen), in Synsema

[Vela](https://docs.horizen.io/vela/introduction/) runs your application inside a TEE and settles
every result on-chain. Its official toolchain is Go + TinyGo. This kit gives you the other one:
the app is **one `.syn` file** with its tests, the module is built for you (locally or by CI), and
the side outside the enclave — keys, deploy, encrypted requests, events, reports, gasless
meta-transactions — is a Synsema program too. Ten minutes from clone to a request settled
on-chain, without learning the ABI.

Everything here is verified against Horizen's starter kit v0.2.0 (the real Executor, the real
contracts). The full reference is the docs page [Vela (Horizen)](https://synsema.dev/en/0.6.x/73-vela);
the adapter and its README live in [kitecosmic/synsema — packages/guests/vela](https://github.com/kitecosmic/synsema/tree/main/packages/guests/vela).

## What you get

```
app/app.syn                  your app: deploy · load_module · deposit · process · deanonymize · trusted, with tests
client/vela_client.syn       the client: keys, register, deploy, deposit ETH/ERC-20, encrypted send, reports, events, facilitator
client/.env.example          addresses, URLs and keys the client reads
scripts/build.sh             app/app.syn → build/app.wasm (the release's guest module with your program in its slot) + sha256
scripts/embed.syn            puts a .syn into the app slot of a guest module — what build.sh runs; no compiler
scripts/smoke.mjs            generic probe of a module under Node's WASI, the way the Executor drives it
scripts/devnet.sh            Horizen's starter kit in Docker (nine containers), and client/.env written for it
scripts/e2e.sh               keys → deploy → register → deposit → send → events, end to end
.github/workflows/build.yml  CI: tests, build, Node 24 + wasmtime-go probes, build/app.wasm as an artifact
syn.toml                     the recipe descriptor for the Synsema platform (phase 2)
```

## Ten minutes

You need the [`synsema` binary](https://synsema.org) (`npm i -g synsema`, or the install script). That is
all: the module is the release's guest with your program in its slot — no compiler, a few seconds.
To run the stack locally you need Docker; without Docker, `synsema run vela_client.syn -- devnet` writes a
token of your own on the public devnet into `client/.env`.

```sh
synsema test app/app.syn                 # 1. the app, natively — the same code runs in the enclave
sh scripts/build.sh                      # 2. build/app.wasm: the release's guest + your program (the guest downloads once)
node scripts/smoke.mjs build/app.wasm    #    Node 20 or 24+ (not 22): imports, exports, load_module, deploy, determinism
sh scripts/devnet.sh                     # 3. Vela in Docker; writes client/.env with the deployed addresses
sh scripts/e2e.sh                        # 4. keys, deploy, register, deposit, an encrypted request, your events decrypted
```

Then edit `app/app.syn` — the instructions live in `process` — run step 1 again, rebuild, and
redeploy with `sh scripts/e2e.sh` (every deploy is a new application id; the client stores it in
`client/.env`).

## The app

One task per Vela entry point; each receives one map and returns one map:

| Vela calls | your task | receives | returns |
|---|---|---|---|
| `deploy` | `deploy(ctx)` | `{app_id, params}` (constructor JSON, `nothing` if empty) | `{state, fuel?}` |
| `load_module` | `load_module(ctx)` | `{app_id}` — cache warm-up after an Executor restart, the state is discarded | `{state, fuel?}` |
| `deposit` | `deposit(ctx)` | `{sender, token, value, value_hex, state}` — a deposit of ETH or an allowlisted ERC-20 | `{state?, events?, app_events?, fuel?, error?}` |
| `process_request` (1) | `process(ctx)` | `{sender, payload, payload_hex, state}` — the user's decrypted payload | `{state?, events?, app_events?, withdrawals?, fuel?, error?}` |
| `process_request` (2) | `deanonymize(ctx)` | same, from an allowed authority | `{report, state?, fuel?}` |
| `trusted_request` | `trusted(ctx)` | `{payload_hex, state}` — ABI bytes from a trigger contract, no sender | like `process`, with no `app_events` |

The rules that matter, all enforced by the adapter or by Vela itself:

- **Deterministic by construction.** No `now()`, no `random()`, no network: the guest runs under a
  ceiling that denies them, because Vela signs the state root. Maps keep insertion order, so the
  same input gives the same bytes.
- **Amounts as text.** `text(n)` keeps 256-bit values exact; the adapter turns them into Vela's hex.
  A bare JSON number above 2⁵³ would come back as a float.
- **Events need registered users.** An event for an address without a P-521 key fails the whole
  request. Register with `vela_client.syn -- register`.
- **Declare `fuel`.** Vela charges it against the request's `maxFeeValue`; the template uses the
  reference app's constants (5 / 20 / 35 / 50).
- **Bytes for contracts.** `data_hex`, `state_hex`, `report_hex` carry exact bytes (what a contract
  `abi.decode`s); `subtype` is `0x…` + 64 hex or a label of at most 32 bytes.

## The client

`client/vela_client.syn` speaks every part of Vela's client protocol, natively:

| `synsema run vela_client.syn -- …` | does |
|---|---|
| `keys` · `address` · `tee` | a P-521 pair for `.env` · your signing address · the Executor's key read on-chain |
| `deploy <wasm> [params-json\|-] [trigger]` | uploads the module to the authority service and submits the on-chain deploy (with a trigger contract if given); waits; prints the app id |
| `register` | AssociateKey: your P-521 public key and a privacy seed, encrypted for the Executor |
| `deposit <amount> [token]` | ETH (wei) or an allowlisted ERC-20 (approves first) |
| `send '<json>' [wei]` | a PROCESS request, payload encrypted for the Executor; optional ETH deposit with it |
| `report '<json>'` · `report-download <id>` | a deanonymization report (the caller must be an allowed authority), fetched and decrypted |
| `events [n]` · `app-events [n]` · `status <id>` | your events decrypted · the app's public events · a request's status |
| `user` · `register-for` · `send-for '<json>' [amount token]` · `events-for [n]` | the facilitator flow: a user with no ETH signs EIP-712 typed data (and an EIP-2612 permit for a token deposit); `VELA_SECP_KEY` pays |

Configuration is `client/.env` (copy `.env.example`). `scripts/devnet.sh` fills in the local
addresses; `synsema run vela_client.syn -- devnet` writes the public devnet's lines with a token of your own
(`allow-token` and `allow-authority` then run with the admin key, Anvil #0 there).

## Trigger contracts, ERC-20, facilitator

The template's `trusted` task already decodes an ABI payload from a trigger contract. A complete
execution-pool app with its Solidity trigger, an ERC-20 with `permit`, and the scripts to deploy
them with `forge` are in the adapter's repository under `examples/`; the docs page walks through
the trigger cycle step by step.

## Gotchas

- Node 22 crashes intermittently inside V8 running this module; use Node 20 or 24+, or add
  `--no-wasm-dynamic-tiering`. wasmtime-go (the Executor's runtime) is unaffected.
- Deploying needs an account with `DEPLOYER_ROLE` (Anvil #0 on the local kit); deanonymization
  needs the caller allowed in `DefaultAuthority`; ERC-20s need the `TokenAllowlist`.
- `to` and `from` are reserved words in Synsema; there are no `0xab` literals (write `171`).
- On Windows, run the scripts from Git Bash.

## Guía rápida (español)

1. `synsema test app/app.syn` — la app, nativa. 2. `sh scripts/build.sh` — el módulo. 3. `sh scripts/devnet.sh` —
Vela en Docker. 4. `sh scripts/e2e.sh` — claves, deploy, registro, depósito, un request cifrado y tus eventos
descifrados. Después editá `process` en `app/app.syn` y repetí. La referencia completa en español está en
[synsema.dev/es/0.6.x/73-vela](https://synsema.dev/es/0.6.x/73-vela).

## License

Apache-2.0.
