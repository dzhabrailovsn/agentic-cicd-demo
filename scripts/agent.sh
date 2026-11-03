#!/usr/bin/env bash
# Обёртка headless-агента: prompt + context-файлы -> валидный JSON.
#
# Usage: bash agent.sh <prompt.md> <output.json> [context-file ...]
#
# Бэкенды (repo variable AGENT_BACKEND):
#   gh-models   — GitHub Models API через GITHUB_TOKEN (job требует permissions models: read).
#                 Модель — GH_MODEL (default: openai/gpt-4o-mini). Внешние секреты не нужны.
#   cli         — внешняя headless-команда AGENT_CMD ("zcode -p" / "claude -p" / ...).
#
# Env:
#   AGENT_BACKEND       gh-models | cli (default: cli)
#   AGENT_CMD           команда CLI-агента (backend=cli)
#   AGENT_API_KEY       ключ API CLI-агента (backend=cli)
#   GH_MODEL            модель GitHub Models (backend=gh-models)
#   GH_MODELS_ENDPOINT  переопределение endpoint (default https://models.github.ai/inference/chat/completions)
#   GITHUB_TOKEN        токен Actions (backend=gh-models)
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

# Backend 1: внешняя headless-команда.
call_cli() {
  local combined="$1" out="$2"
  if [[ -z "${AGENT_CMD:-}" ]]; then
    echo "::error::AGENT_CMD не задан (backend=cli). Задайте repo variable AGENT_CMD или включите AGENT_BACKEND=gh-models" >&2
    return 1
  fi
  "$AGENT_CMD" "$(cat "$combined")" > "$out.raw" 2> "$out.err" || true
}

# Backend 2: GitHub Models через GITHUB_TOKEN.
call_gh_models() {
  local combined="$1" out="$2"
  local model="${GH_MODEL:-openai/gpt-4o-mini}"
  local endpoint="${GH_MODELS_ENDPOINT:-https://models.github.ai/inference/chat/completions}"
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "::error::GITHUB_TOKEN недоступен — добавьте в job permissions: models: read" >&2
    return 1
  fi
  local payload resp
  payload="$(jq -n \
    --arg model "$model" \
    --arg system 'Ты — автоматизационный агент в CI/CD. Твой ответ должен быть СТРОГО одним JSON-объектом без markdown-фенсов и пояснений, строго по схеме из промпта.' \
    --arg user "$(cat "$combined")" \
    '{model: $model, temperature: 0, max_tokens: 4000, messages: [{role:"system", content:$system}, {role:"user", content:$user}]}')"
  if ! resp="$(curl -sS --max-time 120 -X POST "$endpoint" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" 2> "$out.err")"; then
    echo "::error::curl к GitHub Models не удался" >&2
    return 1
  fi
  if jq -e '.choices[0].message.content' >/dev/null 2>&1 <<< "$resp"; then
    jq -r '.choices[0].message.content' <<< "$resp" > "$out.raw"
    echo "==> gh-models ($model): ответ получен ($(wc -c < "$out.raw") байт)"
    return 0
  fi
  echo "::error::GitHub Models вернул ошибку: $(echo "$resp" | head -c 300)" >&2
  return 1
}

MAX_ATTEMPTS="${AGENT_MAX_ATTEMPTS:-2}"
BACKEND="${AGENT_BACKEND:-cli}"
case "$BACKEND" in
  cli|gh-models) ;;
  *) echo "::error::неизвестный AGENT_BACKEND '$BACKEND' (допустимо: cli, gh-models)"; exit 1 ;;
esac

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
  echo "==> agent attempt $attempt/$MAX_ATTEMPTS (backend: $BACKEND)"
  case "$BACKEND" in
    cli)       call_cli "$COMBINED" "$OUTPUT_FILE" ;;
    gh-models) call_gh_models "$COMBINED" "$OUTPUT_FILE" ;;
  esac
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
