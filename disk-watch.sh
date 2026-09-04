#!/usr/bin/env bash
# Disk watchdog. Appends one line per run to disk-watch.log next to this script.
#
# Why it exists: a ClickHouse merge loop filled this host's disk over 30 days without a
# single warning - the first symptom was the disk hitting 100%. This catches both shapes
# of that failure: the slow one (a percentage threshold) and the fast one (a projection of
# days remaining), so it does not depend on guessing what the next bug will be.
#
# It is deliberately independent of Docker, ClickHouse and SigNoz. The incident was the
# monitoring stack filling its own disk; an alert living inside that stack would have died
# with it.
#
#   ./disk-watch.sh --status    read the log and the current state
#   ./disk-watch.sh             take one measurement (this is what cron runs)
#   0 * * * * /path/to/disk-watch.sh
set -uo pipefail

MOUNT="${MOUNT:-/}"
PCT_WARN="${PCT_WARN:-75}"        # alert at or above this percentage used
DAYS_WARN="${DAYS_WARN:-30}"      # alert when the disk is projected to fill within this
KEEP_LINES="${KEEP_LINES:-2000}"  # roughly 3 months of hourly runs; keeps this from growing

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/disk-watch.log"
STATE="$HERE/.disk-watch"
SAMPLES="$STATE/samples"
mkdir -p "$STATE"

# ── Read mode ─────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--status" ]; then
  [ -f "$LOG" ] || { echo "no data yet - run ./disk-watch.sh once"; exit 0; }
  echo "── last 10 measurements ──"
  tail -10 "$LOG"
  n=$(grep -c ALERT "$LOG" 2>/dev/null) || n=0   # grep -c already prints 0 when it finds none
  echo
  if [ "$n" -gt 0 ]; then
    echo "── $n ALERT lines, most recent ──"; grep ALERT "$LOG" | tail -3
  else
    echo "no ALERT lines so far."
  fi
  # Staleness of the last line is the proof of life for cron itself, so no heartbeat is needed.
  age=$(( ($(date +%s) - $(stat -c %Y "$LOG")) / 60 ))
  [ "$age" -gt 90 ] && echo "!! last write was $age minutes ago - cron may have stopped"
  exit 0
fi

# ── Measure ───────────────────────────────────────────────────────────────────────────
read -r TOTAL USED AVAIL < <(df -B1 --output=size,used,avail "$MOUNT" | tail -1)
PCT=$(( USED * 100 / TOTAL ))
NOW=$(date +%s)

echo "$NOW $USED" >> "$SAMPLES"
awk -v c=$((NOW - 8*86400)) '$1 >= c' "$SAMPLES" > "$SAMPLES.t" && mv "$SAMPLES.t" "$SAMPLES"

# Rate is measured against the oldest sample still in the 8-day window. At least an hour of
# history is required, otherwise short-term noise dominates and the projection is useless.
read -r RATE DAYS < <(awk -v now="$NOW" -v used="$USED" -v avail="$AVAIL" '
  NR==1 { t0=$1; u0=$2 }
  END {
    dt = now - t0
    if (dt < 3600) { print "na na"; exit }
    r = (used - u0) / dt * 86400 / 1073741824
    if (r <= 0.01) printf "%.2f na\n", r
    else           printf "%.2f %.0f\n", r, avail/1073741824/r
  }' "$SAMPLES")

# ── Decide ────────────────────────────────────────────────────────────────────────────
STATUS="OK"; WHY=""
if [ "$PCT" -ge "$PCT_WARN" ]; then
  STATUS="ALERT"; WHY="${PCT}% used, at or above ${PCT_WARN}%"
fi
if [ "$DAYS" != "na" ] && [ "$DAYS" -lt "$DAYS_WARN" ]; then
  STATUS="ALERT"
  WHY="${WHY:+$WHY; }projected full in ~${DAYS} days (under ${DAYS_WARN})"
fi

LINE=$(printf '%s  %3d%%  %6.1f/%.1fGB  free %6.1fGB  %8s  %6s  %s%s' \
  "$(date '+%Y-%m-%d %H:%M')" "$PCT" \
  "$(awk -v x="$USED" 'BEGIN{print x/1073741824}')" \
  "$(awk -v x="$TOTAL" 'BEGIN{print x/1073741824}')" \
  "$(awk -v x="$AVAIL" 'BEGIN{print x/1073741824}')" \
  "$([ "$RATE" = na ] && echo '-' || printf '%+.2fGB/d' "$RATE")" \
  "$([ "$DAYS" = na ] && echo '-' || echo "~${DAYS}d")" \
  "$STATUS" "${WHY:+ - $WHY}")

echo "$LINE" >> "$LOG"

# On alert, record where to look next, so whoever reads this months from now does not have
# to rediscover it. Also print to stdout, which cron mails if an MTA is configured.
if [ "$STATUS" = ALERT ]; then
  {
    echo "    look first at container logs without rotation, and at ClickHouse system databases:"
    echo "      for c in \$(docker ps --format '{{.Names}}'); do echo \"\$(docker logs \$c 2>&1|wc -c) \$c\"; done | sort -rn | head"
    echo "      docker system df"
  } >> "$LOG"
  echo "$LINE"
fi

# Keep this from becoming a source of the very problem it watches for.
if [ "$(wc -l < "$LOG")" -gt "$KEEP_LINES" ]; then
  tail -n "$KEEP_LINES" "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"
fi
