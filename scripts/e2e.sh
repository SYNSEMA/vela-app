#!/bin/sh
# The whole loop against a Vela stack (the local devnet or a hosted one, per client/.env):
# keys (once) → deploy build/app.wasm → register → deposit → an encrypted request → decrypted events.
#
#   sh scripts/e2e.sh                                   # deploys build/app.wasm, sends the template's transfer (with an invoice), withdraws, asks for the tx_history report
#   APP_WASM=other.wasm PARAMS='{"k":1}' PAYLOAD='{"type":"…"}' DEPOSIT_WEI=1000 sh scripts/e2e.sh
#   E2E_REPORT=0 sh scripts/e2e.sh                      # skip allow-authority + the report at the end
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_WASM="${APP_WASM:-$ROOT/build/app.wasm}"
PARAMS="${PARAMS:--}"
DEPOSIT_WEI="${DEPOSIT_WEI:-100000000000000000}"
cd "$ROOT/client"
[ -f .env ] || { echo "client/.env is missing: run scripts/devnet.sh, or copy .env.example and point it at a hosted devnet"; exit 2; }
[ -f "$APP_WASM" ] || { echo "$APP_WASM is missing: run scripts/build.sh (or download the CI artifact)"; exit 2; }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) APP_WASM="$(cygpath -w "$APP_WASM")" ;; esac

run() { synsema run vela_client.syn -- "$@"; }

if ! grep -q '^VELA_P521_KEY=.\{10,\}' .env; then
  echo "== keys: a fresh P-521 pair, written to .env"
  KEYS="$(run keys)"
  PRIV="$(echo "$KEYS" | sed -n 's/^VELA_P521_KEY=//p')"; PUB="$(echo "$KEYS" | sed -n 's/^VELA_P521_PUB=//p')"
  sed -i.bak "s/^VELA_P521_KEY=.*/VELA_P521_KEY=$PRIV/; s/^VELA_P521_PUB=.*/VELA_P521_PUB=$PUB/" .env && rm -f .env.bak
fi

ME="$(run address | tail -1)"
echo "== signing address: $ME"
echo "== deploy $APP_WASM"
OUT="$(run deploy "$APP_WASM" "$PARAMS")"; echo "$OUT"
APP_ID="$(echo "$OUT" | sed -n 's/.*VELA_APP_ID=\([0-9]*\).*/\1/p')"
[ -n "$APP_ID" ] || { echo "no application id in the deploy output"; exit 1; }
sed -i.bak "s/^VELA_APP_ID=.*/VELA_APP_ID=$APP_ID/" .env && rm -f .env.bak

echo "== register"; run register
echo "== deposit $DEPOSIT_WEI wei"; run deposit "$DEPOSIT_WEI"
TEMPLATE=0
if [ -z "${PAYLOAD:-}" ]; then
  # the template's own instruction: a transfer to the signing address itself, with an invoice (a public keccak receipt)
  PAYLOAD="{\"type\":\"transfer\",\"to\":\"$ME\",\"amount\":\"1000\",\"invoice_id\":\"INV-1\"}"
  TEMPLATE=1
fi
echo "== send $PAYLOAD"; run send "$PAYLOAD"
if [ -z "${PAYLOAD2:-}" ] && [ "$TEMPLATE" = 1 ]; then
  # the template's withdraw: a pull-payment on-chain plus a public ABI receipt (app event)
  PAYLOAD2="{\"type\":\"withdraw\",\"to\":\"$ME\",\"amount\":\"500\"}"
fi
if [ -n "${PAYLOAD2:-}" ]; then echo "== send $PAYLOAD2"; run send "$PAYLOAD2"; fi
echo "== events (yours, decrypted)"; run events 3
echo "== balance (from your newest event)"; run balance
echo "== app-events (public: the invoice receipt and the withdrawal)"; run app-events 2
if [ "${E2E_REPORT:-1}" = 1 ]; then
  echo "== allow-authority $APP_ID $ME"; run allow-authority "$APP_ID" "$ME"
  echo "== history $ME (the tx_history report, decrypted)"; run history "$ME"
fi
echo "done: VELA_APP_ID=$APP_ID is in client/.env"
