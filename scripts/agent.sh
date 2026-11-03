#!/usr/bin/env bash
# Обёртка headless-агента: prompt + context-файлы -> валидный JSON.
#
# Usage: bash agent.sh <prompt.md> <output.json> [context-file ...]
#
# Env:
#   AGENT_CMD           команда headless-агента: "zcode -p" / "claude -p" / ...
#   AGENT_MAX_ATTEMPTS  попыток получить валидный JSON (default: 2)
#
# Политика fail-closed: нет валидного JSON -> exit 1 (гейт не пропустит).

set -euo pipefail

PROMPT_FILE="${1:?usage: agent.sh <prompt.md> <output.json> [context ...]}"
OUTPUT_FILE="${2:?usage: agent.sh <prompt.md> <output.json> [context ...]}"
shift 2

# Вытащить первый JSON-объект из ответа модели (она может добавить prose/фенсы).
extract_json() {
  local raw="$1" out="$2"
  if jq -e . "$raw" >/dev/null 2>&1; then
    cp "$raw" "$out"; return 0
  fi
  # срезать markdown-фенсы, взять текст от первого '{' до последнего '}'
  sed -e 's/^```.*$//' "$raw" \
    | awk 'BEGIN{f=0} f==0 && /\{/{f=1} f{print}' \
    | tac \
    | awk 'BEGIN{f=0} f==0 && /\}/{f=1} f{print}' \
    | tac > "$out.try" || return 1
  jq -e . "$out.try" >/dev/null 2>&1 || return 1
  mv "$out.try" "$out"
}

if [[ -z "${AGENT_CMD:-}" ]]; then
  echo "::error::AGENT_CMD не задан (repo variable). Примеры: 'zcode -p', 'claude -p', 'copilot -p'" >&2
  exit 1
fi

MAX_ATTEMPTS="${AGENT_MAX_ATTEMPTS:-2}"

COMBINED="$(mktemp)"
trap 'rm -f "$COMBINED" "$OUTPUT_FILE.raw" "$OUTPUT_FILE.err" "$OUTPUT_FILE.try"' EXIT

{
  echo "===== PROMPT ====="
  cat "$PROMPT_FILE"
  for f in "$@"; do
    echo
    if [[ -s "$f" ]]; then
      echo "===== CONTEXT: $f ====="
      cat "$f"
    else
      echo "===== CONTEXT: $f (пусто/отсутствует) ====="
    fi
  done
} > "$COMBINED"

attempt=1
while :; do
  echo "==> agent attempt $attempt/$MAX_ATTEMPTS"
  "$AGENT_CMD" "$(cat "$COMBINED")" > "$OUTPUT_FILE.raw" 2> "$OUTPUT_FILE.err" || true
  if extract_json "$OUTPUT_FILE.raw" "$OUTPUT_FILE"; then
    echo "==> verdict OK"
    jq -c . "$OUTPUT_FILE"
    exit 0
  fi
  (( attempt >= MAX_ATTEMPTS )) && break
  attempt=$((attempt + 1))
done

echo "::error::агент не вернул валидный JSON за $MAX_ATTEMPTS попыток; последние строки stderr:" >&2
tail -n 15 "$OUTPUT_FILE.err" >&2 2>/dev/null || true
exit 1
