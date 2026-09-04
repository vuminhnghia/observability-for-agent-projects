#!/usr/bin/env bash
# Apply this repository's local customisations to the upstream Opik clone.
#
# Run this after every `git pull` inside opik/, because one of the three changes lands in
# a file that upstream owns and will therefore be overwritten. The script is idempotent:
# running it when everything is already in place changes nothing and reports so.
#
#   ./opik-overlay/apply.sh            apply, then print what to do next
#   ./opik-overlay/apply.sh --check    report only, change nothing (exit 1 if drift)
#
# See the repository README for why each change exists.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPIK="$HERE/../opik"
COMPOSE_DIR="$OPIK/deployment/docker-compose"
COMPOSE="$COMPOSE_DIR/docker-compose.yaml"
CH_VOLUME="opik-opik_clickhouse-config"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

fail() { echo "ERROR: $*" >&2; exit 1; }
[ -f "$COMPOSE" ] || fail "upstream compose file not found at $COMPOSE - is opik/ cloned?"

drift=0
note() { echo "  $*"; }

# ── 1. ClickHouse server config: system-table TTLs + Compact parts for metric_log ──────
# Lives in a Docker volume, so it survives `git pull` and container recreation. Opik's
# clickhouse-init only copies its own files in, it never deletes unknown ones.
echo "[1/3] server config -> volume $CH_VOLUME"
if ! docker volume inspect "$CH_VOLUME" >/dev/null 2>&1; then
  note "volume does not exist yet; it is created the first time the Opik stack starts."
  note "re-run this script after the first start."
  drift=1
else
  current=$(docker run --rm -v "$CH_VOLUME":/cfg alpine cat /cfg/zz-local.xml 2>/dev/null || true)
  wanted=$(cat "$HERE/clickhouse-config.d/zz-local.xml")
  if [ "$current" = "$wanted" ]; then
    note "already up to date"
  else
    drift=1
    if [ "$CHECK_ONLY" = 1 ]; then
      note "DRIFT: zz-local.xml missing or differs"
    else
      docker run --rm -v "$CH_VOLUME":/cfg -v "$HERE/clickhouse-config.d":/src:ro alpine \
        sh -c 'cp /src/zz-local.xml /cfg/zz-local.xml && chown 1000:1000 /cfg/zz-local.xml' \
        || fail "could not write into volume $CH_VOLUME"
      note "installed"
    fi
  fi
fi

# ── 2. ClickHouse user config: disable the query profiler ─────────────────────────────
# Untracked by upstream git, so a `git pull` leaves it alone. It has to be a real file on
# disk because it is bind-mounted (a user-level setting cannot go in config.d/).
echo "[2/3] user config -> $COMPOSE_DIR/clickhouse_config/users.d/zz-local-users.xml"
dest="$COMPOSE_DIR/clickhouse_config/users.d/zz-local-users.xml"
if [ -f "$dest" ] && cmp -s "$HERE/clickhouse-users.d/zz-local-users.xml" "$dest"; then
  note "already up to date"
else
  drift=1
  if [ "$CHECK_ONLY" = 1 ]; then
    note "DRIFT: file missing or differs"
  else
    mkdir -p "$(dirname "$dest")"
    cp "$HERE/clickhouse-users.d/zz-local-users.xml" "$dest"
    note "installed"
  fi
fi

# ── 3. Compose service definition: healthcheck, log rotation, extra mount ─────────────
# This is the only change inside a file upstream owns, so it is the only one a `git pull`
# can undo. Edited as scoped text rather than by rewriting the YAML, to keep upstream
# formatting and comments intact.
echo "[3/3] compose service 'clickhouse' -> $COMPOSE"
python3 - "$COMPOSE" "$CHECK_ONLY" <<'PY'
import re, sys, pathlib

path, check_only = pathlib.Path(sys.argv[1]), sys.argv[2] == "1"
src = path.read_text()

MOUNT = "      - ./clickhouse_config/users.d/zz-local-users.xml:/etc/clickhouse-server/users.d/zz-local-users.xml\n"
LOGGING = """    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
"""
HEALTHCHECK = """    healthcheck:
      # `--spider` closes the socket after the headers, so ClickHouse loses the connection
      # mid-body and logs two ERROR lines per ping. Measured: 30 pings with --spider produced
      # 46 error lines, 30 pings with `-O /dev/null` produced zero. At the upstream interval
      # of 1s that came to about 173k error lines a day.
      test: [ "CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8123/ping" ]
      interval: 30s
      timeout: 10s
      start_period: 40s
      retries: 5
"""

# Narrow the edit to the `clickhouse:` service block only.
m = re.search(r"^  clickhouse:\n(?:.*\n)*?(?=^  \S|\Z)", src, re.M)
if not m:
    print("  ERROR: could not locate the 'clickhouse:' service block", file=sys.stderr)
    sys.exit(2)
block = m.group(0)
new = block

if MOUNT not in new:
    anchor = "      - ./clickhouse_config/users.d/enable_time_type.xml:/etc/clickhouse-server/users.d/enable_time_type.xml\n"
    if anchor not in new:
        print("  ERROR: expected volume anchor not found; upstream layout changed", file=sys.stderr)
        sys.exit(2)
    new = new.replace(anchor, anchor + MOUNT, 1)

if "\n    logging:\n" not in new:
    new = re.sub(r"^    healthcheck:\n", LOGGING + "    healthcheck:\n", new, count=1, flags=re.M)

hc = re.search(r"^    healthcheck:\n(?:      .*\n|      # .*\n)*", new, re.M)
if not hc:
    print("  ERROR: no healthcheck block in the clickhouse service", file=sys.stderr)
    sys.exit(2)
if "-O" not in hc.group(0) or "interval: 30s" not in hc.group(0):
    new = new[:hc.start()] + HEALTHCHECK + new[hc.end():]

if new == block:
    print("  already up to date")
    sys.exit(0)
if check_only:
    print("  DRIFT: healthcheck / logging / mount not as expected")
    sys.exit(1)
path.write_text(src.replace(block, new, 1))
print("  patched")
PY
rc=$?
[ "$rc" -ge 2 ] && fail "compose edit failed - inspect $COMPOSE by hand"
[ "$rc" = 1 ] && drift=1

echo
if [ "$CHECK_ONLY" = 1 ]; then
  [ "$drift" = 0 ] && { echo "All three customisations are in place."; exit 0; }
  echo "Drift detected. Run ./opik-overlay/apply.sh to fix."; exit 1
fi
if [ "$drift" = 0 ]; then
  echo "Nothing to do - all three customisations were already in place."
else
  cat <<'EOF'
Applied. The compose and mount changes only take effect on a new container:

  cd opik/deployment/docker-compose
  docker compose -p opik-opik -f docker-compose.yaml --profile opik \
    up -d --force-recreate --no-deps clickhouse

Changing metric_log's engine makes ClickHouse rename the previous system log tables to
`<name>_0` and keep all their data, so drop them afterwards or the old rows stay forever:

  docker exec opik-opik-clickhouse-1 clickhouse-client --query \
    "SELECT name FROM system.tables WHERE database='system' AND name LIKE '%\_0'"
  # then, for each name returned:
  docker exec opik-opik-clickhouse-1 clickhouse-client --query \
    "DROP TABLE IF EXISTS system.<name> SYNC"
EOF
fi
