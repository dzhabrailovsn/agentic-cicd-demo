#!/usr/bin/env bash
# Health-проба: N запросов к URL, строки "probe=i status=<code> latency=<s>" + фрагменты тел 2xx.
# Usage: bash health.sh <url> [attempts=5] [interval_sec=3]
set -euo pipefail

URL="${1:?usage: health.sh <url> [attempts] [interval_sec]}"
ATTEMPTS="${2:-5}"
INTERVAL="${3:-3}"

[[ -n "$URL" ]] || { echo "::error::URL не задан"; exit 1; }
BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT

ok=0
for i in "$(seq 1 "$ATTEMPTS")"; do
  out="$(curl -sS -o "$BODY" -w '%{http_code} %{time_total}' --max-time 10 "$URL" 2>/dev/null || echo '000 0')"
  code="${out%% *}"; lat="${out##* }"
  echo "probe=$i status=$code latency=${lat}s"
  if [[ "$code" == 2* ]]; then
    ok=$((ok + 1))
    head -c 400 "$BODY" 2>/dev/null || true
    echo
  fi
  [[ "$i" != "$ATTEMPTS" ]] && sleep "$INTERVAL"
done
echo "summary ok=$ok/$ATTEMPTS"

[[ "$ok" -gt 0 ]]
