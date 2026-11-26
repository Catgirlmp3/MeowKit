#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/miner.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE"
cat > "$FIXTURE/meowkit-xmrig" <<'EOF'
#!/usr/bin/env sh
echo 'XMRig 6.26.0'
EOF
chmod 755 "$FIXTURE/meowkit-xmrig"
(cd "$FIXTURE" && sha256sum meowkit-xmrig > SHA256SUMS)

begin_step() { :; }
info() { :; }
warn() { :; }
fail() { echo "FAIL: $*" >&2; exit 1; }
make_workdir() { WORKDIR=$(mktemp -d "$TMP/work.XXXXXX"); }

CURL_MODE=''
CURL_TRACE=()
curl() {
  local output='' url='' tor=0
  while (($#)); do
    case "$1" in
      --socks5-hostname) tor=1; shift ;;
      --output) output=$2; shift 2 ;;
      https://*) url=$1; shift ;;
      *) shift ;;
    esac
  done
  CURL_TRACE+=("$([[ $tor == 1 ]] && echo tor || echo normal)")
  if [[ $tor == 1 && $CURL_MODE != tor ]]; then return 1; fi
  case "$url" in
    */SHA256SUMS) cp "$FIXTURE/SHA256SUMS" "$output" ;;
    */meowkit-xmrig) cp "$FIXTURE/meowkit-xmrig" "$output" ;;
    *) return 1 ;;
  esac
}

setup_case() {
  local name=$1
  ROOT="$TMP/root-$name"
  MEOWKIT_BIN="$TMP/bin-$name/meowkit-xmrig"
  mkdir -p "$ROOT" "$(dirname "$MEOWKIT_BIN")"
  REPAIR=0
  CURL_TRACE=()
  WORKDIR=''
}

# Case 1: the bundled executable is preferred and no network call is made.
setup_case bundled
mkdir -p "$ROOT/vendor/xmrig/linux-x86_64"
cp "$FIXTURE/meowkit-xmrig" "$ROOT/vendor/xmrig/linux-x86_64/meowkit-xmrig"
cp "$FIXTURE/SHA256SUMS" "$ROOT/vendor/xmrig/linux-x86_64/SHA256SUMS"
install_xmrig
[[ -x $MEOWKIT_BIN ]]
[[ ${#CURL_TRACE[@]} -eq 0 ]]
rm -rf "$WORKDIR"

# Case 2: if the bundle is absent, the Tor copy is tried before normal HTTPS.
setup_case tor
CURL_MODE=tor
install_xmrig
[[ -x $MEOWKIT_BIN ]]
[[ ${CURL_TRACE[*]} == 'tor tor' ]]
rm -rf "$WORKDIR"

# Case 3: if Tor fails, normal HTTPS is the final transport fallback.
setup_case normal
CURL_MODE=normal
install_xmrig
[[ -x $MEOWKIT_BIN ]]
[[ ${CURL_TRACE[*]} == 'tor normal normal' ]]
rm -rf "$WORKDIR"

echo 'PASS XMRig installer: bundled binary -> Tor download -> normal HTTPS download'
