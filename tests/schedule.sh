#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf -- "$TMP"' EXIT
D=$TMP/meowkit; mkdir -p "$D"
# Run the real scheduler against a temporary fixture rather than system paths.
sed "s#^D=.*#D=$D#" "$ROOT/commands/schedule.sh" > "$TMP/scheduler.sh"
chmod +x "$TMP/scheduler.sh"
cat > "$D/config.json" <<'EOF'
{"autosave":false,"cpu":{"max-threads-hint":100},"randomx":{}}
EOF
printf 'MEOWKIT_THREADS=16\n' > "$D/runtime.env"
write_schedule(){
  cat > "$D/schedule.conf" <<EOF
SCHEDULE_ENABLED=$1
DAY_START=$2
DAY_END=$3
DAY_THREADS=8
BASE_THREADS=16
TOTAL_THREADS=16
TIMEZONE=UTC
EOF
}
expect_threads(){
  local time=$1 expected=$2 out
  out=$(MEOWKIT_SCHEDULE_NOW="$time" "$TMP/scheduler.sh" --dry-run)
  grep -Fq "Selected threads: $expected" <<<"$out" || {
    printf 'FAIL %s expected %s threads:\n%s\n' "$time" "$expected" "$out" >&2
    exit 1
  }
  printf 'PASS %s -> %s threads\n' "$time" "$expected"
}
write_schedule 1 08:00 16:00
expect_threads 07:59 16
expect_threads 08:00 8
expect_threads 12:30 8
expect_threads 15:59 8
expect_threads 16:00 16
expect_threads 23:59 16
write_schedule 1 22:00 06:00
expect_threads 21:59 16
expect_threads 22:00 8
expect_threads 05:59 8
expect_threads 06:00 16
write_schedule 0 08:00 16:00
expect_threads 12:00 16
echo "All schedule boundary tests passed."
