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

## The workbench

Deploy the recipe on [synsema.com](https://synsema.com) — the project's environment is provisioned
from the public devnet at creation (a token of your own, the addresses, the keys) — or run it
locally: `synsema serve web.syn` from this folder, with `.env` copied from `.env.example` and filled
by `cd client && synsema run vela_client.syn -- devnet`. Then, in the browser:

1. **Deploy the app.** The workbench embeds `app/app.syn` into the release's guest module and deploys
   it to Vela (constructor params and a trigger contract are optional).
2. **Register** your key with the enclave, **deposit** ETH or an allowlisted ERC-20.
3. **Send any payload**, encrypted for the Executor — the template's ledger understands `transfer`
   (with an optional `invoice_id`, which leaves a public receipt) and `withdraw` — and read **your
   events, decrypted**, next to **what the chain sees**.
4. **Users**: a key each, registered through the facilitator (they need no ETH), so a payload that
   names another account has someone to name; each user's page shows what they received and sends
   payloads as them.
5. **Reports**: a deanonymization request, decrypted — every balance, or one account's movements
   (`{"report_type": "tx_history", "address": "0x…"}`); one button allows you as an authority first.

Every action is one request to the enclave: 30 to 60 seconds on a devnet. Edit `process` in
`app/app.syn`, deploy again from the same page (a new application id), and drive it the same way.

## What you get

```
web.syn                      the workbench: deploy · register · deposit · send · events · users · reports (the recipe's entry, kind = web)
pages/                       its two pages
app/app.syn                  your app: deploy · load_module · deposit · process · deanonymize · trusted, with tests — a private ledger with a token allowlist, invoiced transfers with a public receipt, pull-payment withdrawals, a log of the last 50 movements, two reports
client/vela_lib.syn          Vela's client protocol as a module: keys, cipher, submit, events, facilitator, reports, token amounts
client/vela_client.syn       the command line on the same module: keys, register, deploy, deposit ETH/ERC-20, transfer, withdraw, balance, history, any encrypted send, reports, events, facilitator
client/.env.example          addresses, URLs and keys the client reads
scripts/embed_lib.syn        the app slot of a guest module (what build.sh and the workbench use to embed the program)
scripts/build.sh             app/app.syn → build/app.wasm (the release's guest module with your program in its slot) + sha256
scripts/embed.syn            puts a .syn into the app slot of a guest module — what build.sh runs; no compiler
scripts/smoke.mjs            generic probe of a module under Node's WASI, the way the Executor drives it
scripts/devnet.sh            Horizen's starter kit in Docker (nine containers), and client/.env written for it
scripts/e2e.sh               keys → deploy → register → deposit → send → events, end to end
.github/workflows/build.yml  CI: tests, build, Node 24 + wasmtime-go probes, build/app.wasm as an artifact
syn.toml                     the recipe descriptor: the workbench as entry, the public devnet as default, [provision] for the token
```

## Ten minutes, from the terminal

You need the [`synsema` binary](https://synsema.org) (`npm i -g synsema`, or the install script). That is
all: the module is the release's guest with your program in its slot — no compiler, a few seconds.
To run the stack locally you need Docker; without Docker, `synsema run vela_client.syn -- devnet` writes a
token of your own on the public devnet into `client/.env`.

```sh
synsema test app/app.syn                 # 1. the app, natively — the same code runs in the enclave
sh scripts/build.sh                      # 2. build/app.wasm: the release's guest + your program (the guest downloads once)
node scripts/smoke.mjs build/app.wasm    #    Node 20 or 24+ (not 22): imports, exports, load_module, deploy, determinism
sh scripts/devnet.sh                     # 3. Vela in Docker; writes client/.env with the deployed addresses
sh scripts/e2e.sh                        # 4. keys, deploy, register, deposit, an invoiced transfer, a withdrawal, your events decrypted, the public receipts, a tx_history report
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

### The template's ledger

What `app/app.syn` does out of the box — the same ground as Horizen's reference app
([`vela-nova`](https://github.com/HorizenOfficial/vela-nova)), in one file:

| | |
|---|---|
| deploy | `{"allowedTokens": ["0x…"]}` as constructor params fixes the ERC-20s the app accepts; ETH is always allowed. A deposit, transfer or withdrawal in any other token is an error. |
| `{"type": "transfer", "to", "amount", "token"?, "invoice_id"?}` | debits the sender, credits `to`, one encrypted event for each. With an `invoice_id` (≤ 100 characters) both events carry it and a public app event goes on-chain whose subtype is `keccak256(abi.encode(invoice, from, token, amount, to))`: whoever holds the invoice can verify the payment, nobody else learns anything. |
| `{"type": "withdraw", "to", "amount", "token"?}` | a pull-payment `to` claims on the ProcessorEndpoint, plus a public ABI receipt `(to, token, amount)` under the label `withdrawal`. |
| the log | the last 50 movements (deposit, transfer, withdrawal, a trigger's credit), each with the nonce of its event. There is no clock in the enclave, so no timestamps: the nonce orders them. |
| report `{}` | every balance, for an allowed authority. |
| report `{"report_type": "tx_history", "address", "from_nonce"?, "to_nonce"?}` | one account's balances and movements, narrowed by nonce (the reference app narrows by timestamp; here that would need a clock the enclave does not have). |

## The client

`client/vela_lib.syn` is Vela's client protocol as a module (`use "./client/vela_lib.syn" as v`: the workbench, the CLI and the other kits build on it); `client/vela_client.syn` is the command line on top of it:

| `synsema run vela_client.syn -- …` | does |
|---|---|
| `keys` · `address` · `tee` | a P-521 pair for `.env` · your signing address · the Executor's key read on-chain |
| `deploy <wasm> [params-json\|-] [trigger]` | uploads the module to the authority service and submits the on-chain deploy (with a trigger contract if given); waits; prints the app id |
| `register` | AssociateKey: your P-521 public key and a privacy seed, encrypted for the Executor |
| `deposit <amount> [token]` | ETH (wei) or an allowlisted ERC-20 (approves first) |
| `send '<json>' [wei]` | a PROCESS request, payload encrypted for the Executor; optional ETH deposit with it |
| `transfer <to> <amount> [token\|-] [invoice]` · `withdraw <to> <amount> [token]` | the template's instructions with the payload built for you; `transfer` prints the receipt's subtype when there is an invoice, `withdraw` the amount now pending for `to` |
| `balance [token]` · `public-balance [token]` · `pending [token] [address]` · `claim [token] [address]` | your private balance (from your newest event) · what you hold on-chain · what a withdrawal (and the fee refunds) left to claim · collect it, for you or for someone else (a plain transaction to the ProcessorEndpoint) |
| `history <address> [from-nonce] [to-nonce]` | one account's `tx_history` report, decrypted (you must be an allowed authority) |
| `report '<json>'` · `report-download <id>` | a deanonymization report (the caller must be an allowed authority), fetched and decrypted |
| `events [n]` · `app-events [n]` · `status <id>` | your events decrypted · the app's public events · a request's status |
| `user` · `register-for` · `send-for '<json>' [amount token]` · `events-for [n]` | the facilitator flow: a user with no ETH signs EIP-712 typed data (and an EIP-2612 permit for a token deposit); `VELA_SECP_KEY` pays |

Configuration is `client/.env` (copy `.env.example`). `scripts/devnet.sh` fills in the local
addresses; `synsema run vela_client.syn -- devnet` writes the public devnet's lines with a token of your own
(the token brings an account of your own — a deployer with ETH and test tokens — and an admin desk,
`VELA_ADMIN_URL`, that signs `allow-token` and `allow-authority` for you).

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

La mesa de trabajo (`synsema serve web.syn`, o la receta en synsema.com con el entorno aprovisionado
desde el devnet público) hace todo desde el navegador: desplegar `app/app.syn`, registrar, depositar,
mandar cualquier payload cifrado, leer tus eventos descifrados y los públicos, usuarios por el
facilitador, reportes. Desde la terminal: 1. `synsema test app/app.syn` — la app, nativa. 2. `sh scripts/build.sh` —
el módulo. 3. `sh scripts/devnet.sh` — Vela en Docker. 4. `sh scripts/e2e.sh` — claves, deploy, registro,
depósito, una transferencia con factura, un retiro, tus eventos descifrados, los recibos públicos y el
reporte `tx_history`. La plantilla ya cubre lo mismo que la app de referencia de Horizen (`vela-nova`):
allowlist de tokens al desplegar, transferencias con factura y recibo público, retiros, el log de los
últimos 50 movimientos y dos reportes. Después editá `process` en `app/app.syn` y repetí. La referencia completa en español está en
[synsema.dev/es/0.6.x/73-vela](https://synsema.dev/es/0.6.x/73-vela).

## License

Apache-2.0.
