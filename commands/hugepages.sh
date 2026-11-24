#!/usr/bin/env bash
set -u
D=/etc/meowkit
CFG=$D/config.json
STATE=$D/hugepages.conf
HP2=/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
HP1=/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
log(){ echo "MeowKit huge pages: $*"; }
RAM_PERCENT=75; HOST_RESERVE_MB=2048
if [[ -r $STATE ]]; then
  # shellcheck source=/dev/null
  source "$STATE"
fi
[[ $RAM_PERCENT =~ ^[0-9]+$ ]] && ((RAM_PERCENT>=10 && RAM_PERCENT<=90)) || RAM_PERCENT=75
[[ $HOST_RESERVE_MB =~ ^[0-9]+$ ]] || HOST_RESERVE_MB=2048
TOTAL_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
[[ $TOTAL_MB =~ ^[0-9]+$ ]] || { log "Cannot read total memory; leaving current reservations unchanged."; exit 0; }
GUEST_MB=0
if command -v qm >/dev/null 2>&1; then
  while read -r id; do
    [[ $id =~ ^[0-9]+$ ]] || continue
    m=$(qm config "$id" 2>/dev/null | awk -F: '$1=="memory"{gsub(/[[:space:]]/,"",$2);print $2;exit}')
    [[ $m =~ ^[0-9]+$ ]] && GUEST_MB=$((GUEST_MB+m))
  done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
fi
if command -v pct >/dev/null 2>&1; then
  while read -r id; do
    [[ $id =~ ^[0-9]+$ ]] || continue
    m=$(pct config "$id" 2>/dev/null | awk -F: '$1=="memory"{gsub(/[[:space:]]/,"",$2);print $2;exit}')
    [[ $m =~ ^[0-9]+$ ]] && GUEST_MB=$((GUEST_MB+m))
  done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
fi
SAFE_MB=$((TOTAL_MB-HOST_RESERVE_MB-GUEST_MB)); ((SAFE_MB>0)) || SAFE_MB=0
NODES=$(python3 -c 's=open("/sys/devices/system/node/online").read().strip(); print(sum((int(y.split("-")[1])-int(y.split("-")[0])+1) if "-" in y else 1 for y in s.split(",") if y))' 2>/dev/null || echo 1)
[[ $NODES =~ ^[1-9][0-9]*$ ]] || NODES=1
TARGET1=$((NODES*3)); ACTUAL1=0; ONE_GB=0
# Try 3 x 1 GiB RandomX pages per NUMA node only when the entire reservation
# fits inside the remaining memory budget and the kernel exposes the pool.
if [[ -r $HP1 && -w $HP1 ]] && (( SAFE_MB >= TARGET1*1024 )); then
  ACTUAL1=$(cat "$HP1" 2>/dev/null || echo 0)
  [[ $ACTUAL1 =~ ^[0-9]+$ ]] || ACTUAL1=0
  if (( ACTUAL1 < TARGET1 )); then
    printf '%s\n' "$TARGET1" > "$HP1" 2>/dev/null || true
    ACTUAL1=$(cat "$HP1" 2>/dev/null || echo 0)
    [[ $ACTUAL1 =~ ^[0-9]+$ ]] || ACTUAL1=0
  fi
  (( ACTUAL1 >= TARGET1 && ACTUAL1*1024 <= SAFE_MB )) && ONE_GB=1
elif [[ -r $HP1 ]]; then
  ACTUAL1=$(cat "$HP1" 2>/dev/null || echo 0)
  [[ $ACTUAL1 =~ ^[0-9]+$ ]] || ACTUAL1=0
fi
RESERVED1=$((ACTUAL1*1024))
REMAIN_MB=$((SAFE_MB-RESERVED1)); ((REMAIN_MB>0)) || REMAIN_MB=0
BUDGET2=$((REMAIN_MB*RAM_PERCENT/100)); TARGET2=$((BUDGET2/2)); ACTUAL2=0
if [[ -r $HP2 && -w $HP2 ]]; then
  ACTUAL2=$(cat "$HP2" 2>/dev/null || echo 0); [[ $ACTUAL2 =~ ^[0-9]+$ ]] || ACTUAL2=0
  if (( TARGET2 > ACTUAL2 )); then
    printf '%s\n' "$TARGET2" > "$HP2" 2>/dev/null || true
    ACTUAL2=$(cat "$HP2" 2>/dev/null || echo 0); [[ $ACTUAL2 =~ ^[0-9]+$ ]] || ACTUAL2=0
  fi
else
  log "2 MiB page pool unavailable."
fi
mkdir -p "$D"
tmp=$(mktemp "$D/.hugepages.XXXXXX") || exit 0
{
  printf 'RAM_PERCENT=%s\n' "$RAM_PERCENT"
  printf 'HOST_RESERVE_MB=%s\n' "$HOST_RESERVE_MB"
  printf 'ONE_GB_PAGES=%s\n' "$ONE_GB"
  printf 'NUMA_NODES=%s\n' "$NODES"
  printf 'GUEST_RESERVE_MB=%s\n' "$GUEST_MB"
  printf 'ONE_GB_ACTUAL_PAGES=%s\n' "$ACTUAL1"
  printf 'TWO_MB_ACTUAL_PAGES=%s\n' "$ACTUAL2"
} > "$tmp"
chmod 600 "$tmp"; mv -f "$tmp" "$STATE"
# Synchronise XMRig's 1 GiB option without touching its other settings.
if [[ -r $CFG ]] && command -v flock >/dev/null 2>&1; then
  exec 8>"$D/.config.lock"; flock -x 8
  python3 - "$CFG" "$ONE_GB" <<'PY'
import json, os, sys, tempfile
path, enabled = sys.argv[1], sys.argv[2] == "1"
try:
    with open(path, encoding="utf-8") as f: data=json.load(f)
    data.setdefault("randomx", {})["1gb-pages"] = enabled
    fd, tmp = tempfile.mkstemp(prefix=".config-pages.", dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(data,f,indent=2); f.write("\n")
    os.chmod(tmp,0o640); os.replace(tmp,path)
except Exception as exc:
    print(f"MeowKit: could not update RandomX 1 GiB page setting: {exc}",file=sys.stderr)
PY
  flock -u 8
fi
if ((ONE_GB)); then log "$ACTUAL1 1 GiB pages enabled across $NODES NUMA node(s)."
else log "1 GiB reservation unavailable/incomplete; retaining 2 MiB fallback."; fi
log "$ACTUAL2 2 MiB pages reserved; host reserve $HOST_RESERVE_MB MiB, Proxmox guest reserve $GUEST_MB MiB, safe budget $SAFE_MB MiB."
exit 0
