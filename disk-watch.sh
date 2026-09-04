#!/usr/bin/env bash
# Canh disk, ghi ra disk-watch.log ngay canh file nay.
#
# Vi sao ton tai: su co metric_log 09/2026 chay 30 ngay hoan toan im lang, den khi
# o day 100% moi biet. Cai nay bat ca hai kieu chet — cham (nguong %) va nhanh
# (nguong so ngay con lai) — nen khong phu thuoc vao viec doan truoc bug la gi.
#
# Doc log:  ./disk-watch.sh --status
# Chay tay: ./disk-watch.sh
# Cron:     0 * * * * /home/nghiavm/workdir/observability/disk-watch.sh
set -uo pipefail

MOUNT="${MOUNT:-/}"
PCT_WARN="${PCT_WARN:-75}"        # keu khi dung >= X%
DAYS_WARN="${DAYS_WARN:-30}"      # keu khi du bao day o trong < X ngay
KEEP_LINES="${KEEP_LINES:-2000}"  # ~3 thang chay moi gio; tu no khong duoc phinh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/disk-watch.log"
STATE="$HERE/.disk-watch"
SAMPLES="$STATE/samples"
mkdir -p "$STATE"

# ─── Che do doc ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--status" ]; then
  [ -f "$LOG" ] || { echo "chua co du lieu — chay ./disk-watch.sh mot lan"; exit 0; }
  echo "── 10 lan do gan nhat ──"
  tail -10 "$LOG"
  n=$(grep -c ALERT "$LOG" 2>/dev/null) || n=0   # grep -c da in 0 khi khong khop
  echo
  if [ "$n" -gt 0 ]; then
    echo "── $n dong ALERT, gan nhat ──"; grep ALERT "$LOG" | tail -3
  else
    echo "chua co ALERT nao."
  fi
  last=$(stat -c %Y "$LOG"); age=$(( ($(date +%s) - last) / 60 ))
  [ "$age" -gt 90 ] && echo "!! lan ghi cuoi $age phut truoc — cron co the da chet"
  exit 0
fi

# ─── Do ──────────────────────────────────────────────────────────────────────
read -r TOTAL USED AVAIL < <(df -B1 --output=size,used,avail "$MOUNT" | tail -1)
PCT=$(( USED * 100 / TOTAL ))
NOW=$(date +%s)

echo "$NOW $USED" >> "$SAMPLES"
awk -v c=$((NOW - 8*86400)) '$1 >= c' "$SAMPLES" > "$SAMPLES.t" && mv "$SAMPLES.t" "$SAMPLES"

# toc do tinh tu mau cu nhat con lai; can >= 1 gio de do nhieu
read -r RATE DAYS < <(awk -v now="$NOW" -v used="$USED" -v avail="$AVAIL" '
  NR==1 { t0=$1; u0=$2 }
  END {
    dt = now - t0
    if (dt < 3600) { print "na na"; exit }
    r = (used - u0) / dt * 86400 / 1073741824
    if (r <= 0.01) printf "%.2f na\n", r
    else           printf "%.2f %.0f\n", r, avail/1073741824/r
  }' "$SAMPLES")

# ─── Quyet dinh ──────────────────────────────────────────────────────────────
STATUS="OK"; WHY=""
if [ "$PCT" -ge "$PCT_WARN" ]; then
  STATUS="ALERT"; WHY="dung ${PCT}% >= ${PCT_WARN}%"
fi
if [ "$DAYS" != "na" ] && [ "$DAYS" -lt "$DAYS_WARN" ]; then
  STATUS="ALERT"
  WHY="${WHY:+$WHY; }day o trong ~${DAYS} ngay (< ${DAYS_WARN})"
fi

LINE=$(printf '%s  %3d%%  %6.1f/%.1fGB  free %6.1fGB  %8s  %6s  %s%s' \
  "$(date '+%Y-%m-%d %H:%M')" "$PCT" \
  "$(awk -v x="$USED" 'BEGIN{print x/1073741824}')" \
  "$(awk -v x="$TOTAL" 'BEGIN{print x/1073741824}')" \
  "$(awk -v x="$AVAIL" 'BEGIN{print x/1073741824}')" \
  "$([ "$RATE" = na ] && echo '-' || printf '%+.2fGB/d' "$RATE")" \
  "$([ "$DAYS" = na ] && echo '-' || echo "~${DAYS}d")" \
  "$STATUS" "${WHY:+ — $WHY}")

echo "$LINE" >> "$LOG"

# ALERT thi ghi them goi y dieu tra, va in ra stdout (cron se mail neu co MTA)
if [ "$STATUS" = ALERT ]; then
  {
    echo "    nghi truoc tien — log container khong rotation, va database system cua ClickHouse:"
    echo "      for c in \$(docker ps --format '{{.Names}}'); do echo \"\$(docker logs \$c 2>&1|wc -c) \$c\"; done | sort -rn | head"
    echo "      docker system df"
  } >> "$LOG"
  echo "$LINE"
fi

# tu gioi han kich thuoc — khong de chinh no thanh nguon day o
if [ "$(wc -l < "$LOG")" -gt "$KEEP_LINES" ]; then
  tail -n "$KEEP_LINES" "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"
fi
