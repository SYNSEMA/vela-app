#!/bin/sh
# Builds app/app.syn into a Vela guest module: build/app.wasm (+ .sha256).
#
# The module is Synsema's interpreter plus your program, exposed through Vela's ABI by the adapter
# in kitecosmic/synsema (packages/guests/vela). This script clones that repo at a release tag into
# .synsema/ and builds the adapter with your app embedded. Needs git, rustup (stable) and the
# wasm32-wasip1 target (added here). First build ≈ 5 min (the interpreter), later ones ≈ 2 min.
# No Rust? Push to GitHub: .github/workflows/build.yml builds it and attaches build/app.wasm.
#
#   sh scripts/build.sh                 # app/app.syn
#   APP=path/to/other.syn sh scripts/build.sh
#   SYNSEMA_TAG=v0.6.22 sh scripts/build.sh   # pin the engine (default below)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNSEMA_TAG="${SYNSEMA_TAG:-v0.6.22}"
APP="${APP:-$ROOT/app/app.syn}"
ENGINE_DIR="$ROOT/.synsema"

if [ ! -d "$ENGINE_DIR" ]; then
  echo "cloning kitecosmic/synsema $SYNSEMA_TAG into .synsema/ …"
  git clone --depth 1 --branch "$SYNSEMA_TAG" https://github.com/kitecosmic/synsema.git "$ENGINE_DIR"
fi
rustup target add wasm32-wasip1 >/dev/null 2>&1 || true

# build.rs reads the program from SYNSEMA_VELA_APP; on Git Bash (Windows) rustc wants a Windows path.
APP_PATH="$APP"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) APP_PATH="$(cygpath -w "$APP")" ;;
esac

echo "building the guest with $APP …"
# SYNSEMA_VERSION is what the module reports as its engine version (the release sets it to the tag).
( cd "$ENGINE_DIR/packages/guests/vela" && SYNSEMA_VELA_APP="$APP_PATH" SYNSEMA_VERSION="$SYNSEMA_TAG" cargo build --profile wasm )

mkdir -p "$ROOT/build"
cp "$ENGINE_DIR/engine/target/wasm32-wasip1/wasm/synsema_vela_guest.wasm" "$ROOT/build/app.wasm"
( cd "$ROOT/build" && sha256sum app.wasm > app.wasm.sha256 )
echo "build/app.wasm: $(wc -c < "$ROOT/build/app.wasm") bytes, sha256 $(cut -d' ' -f1 "$ROOT/build/app.wasm.sha256")"
echo "next: node scripts/smoke.mjs build/app.wasm   (Node 20 or 24+, not 22)"
