#!/usr/bin/env bash
# Обёртка агента: prompt + context-файлы -> валидный JSON.
#
# Usage: bash agent.sh <prompt.md> <output.json> [context-file ...]
#
# Бэкенды (repo variable AGENT_BACKEND):
#   openai  — LLM по OpenAI-протоколу (OpenRouter и любой совместимый провайдер).
#             OPENAI_BASE_URL (default https://openrouter.ai/api/v1),
#             OPENAI_MODEL (default openrouter/free), OPENAI_API_KEY (секрет).
#             Вердикты помечены "backend":"model".
#   heur    — ДЕТЕРМИНИРОВАННЫЕ эвристики без LLM (rule-based анализ диффа/проб/коммитов).
#             Работает без внешних секретов. Вердикты помечены "backend":"heuristic".
#   cli     — внешняя headless-команда AGENT_CMD ("claude -p" / "zcode -p" / ...),
#             требует AGENT_API_KEY. Полноценный LLM-анализ.
#   gh-models — ЗАБРАН: GitHub Models retired 2026-07-30 (api отвечает заглушкой "OK").
#
# FALLBACK: если LLM-бэкенд недоступен (нет ключа / ошибка API / нет валидного
# JSON за AGENT_MAX_ATTEMPTS попыток), выполняется откат на heur (AGENT_FALLBACK,
# default "heur"; "none" отключает — тогда строгий fail-closed exit 1). Бэкенд
# фактического решения всегда виден в поле "backend" вердикта.
#
# Env:
#   AGENT_BACKEND       openai | heur | cli (default: cli)
#   OPENAI_BASE_URL     OpenAI-совместимый endpoint (default https://openrouter.ai/api/v1)
#   OPENAI_MODEL        модель (default openrouter/free — Free Models Router)
#   OPENAI_API_KEY      ключ API (секрет, для openai)
#   AGENT_FALLBACK      heur | none (default heur)
#   AGENT_CMD           команда CLI-агента (backend=cli)
#   AGENT_API_KEY       ключ API CLI-агента (backend=cli)
#   AGENT_MAX_ATTEMPTS  попыток получить валидный JSON (default: 2)
#
# Политика: гейты всегда fail-closed по CONTENT (verdict), LLM-недоступность —
# fallback на детерминированные эвристики, не «молчаливый пропуск».

set -euo pipefail

PROMPT_FILE="${1:?usage: agent.sh <prompt.md> <output.json> [context ...]}"
OUTPUT_FILE="${2:?usage: agent.sh <prompt.md> <output.json> [context ...]}"
shift 2

STAGE="$(basename "$PROMPT_FILE" .md)"

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
    echo "::error::AGENT_CMD не задан (backend=cli). Задайте AGENT_CMD+AGENT_API_KEY или включите AGENT_BACKEND=heur" >&2
    return 1
  fi
  "$AGENT_CMD" "$(cat "$combined")" > "$out.raw" 2> "$out.err" || true
}

# Backend 2: OpenAI-совместимый LLM (OpenRouter и др.).
# Коды возврата: 0 — успех (сырой ответ в <out>.raw); 1 — ошибка вызова (ретрай);
# 2 — конфигурация неполна (нет ключа) — ретраи бессмысленны.
call_openai() {
  local combined="$1" out="$2"
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "::notice::OPENAI_API_KEY не задан — LLM пропущен" >&2
    return 2
  fi
  local base="${OPENAI_BASE_URL:-https://openrouter.ai/api/v1}"
  local model="${OPENAI_MODEL:-openrouter/free}"
  local endpoint="${base%/}/chat/completions"
  local payload resp
  payload="$(jq -n \
    --arg model "$model" \
    --arg system 'Ты — автоматизационный агент в CI/CD. Твой ответ должен быть СТРОГО одним JSON-объектом без markdown-фенсов и пояснений, строго по схеме из промпта.' \
    --arg user "$(cat "$combined")" \
    '{model: $model, temperature: 0, max_tokens: 10000, messages: [{role:"system", content:$system}, {role:"user", content:$user}]}')"
  if ! resp="$(curl -sS --max-time 180 -X POST "$endpoint" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -H "HTTP-Referer: https://github.com/agentic-cicd" \
        -H "X-Title: agentic-cicd-release-train" \
        -d "$payload" 2> "$out.err")"; then
    echo "::error::curl к $endpoint не удался: $(tail -n 2 "$out.err" 2>/dev/null | head -c 200)" >&2
    return 1
  fi
  if jq -e '.choices[0].message.content' >/dev/null 2>&1 <<< "$resp"; then
    jq -r '.choices[0].message.content' <<< "$resp" > "$out.raw"
    echo "==> LLM ($model): ответ получен ($(wc -c < "$out.raw") байт)"
    return 0
  fi
  echo "::error::LLM API вернул ошибку: $(echo "$resp" | head -c 300)" >&2
  return 1
}

# ─── Backend 2: эвристики (детерминированные, без LLM) ───

# По текущей версии из meta-контекста.
_heur_current_version() {
  local meta="$1" v=""
  [[ -n "$meta" && -s "$meta" ]] && v="$(sed -n 's/^current_version: *//p' "$meta" | head -1)"
  echo "${v:-0.0.0}"
}

_bump_version() { # <current> <major|minor|patch>
  local cur="$1" kind="$2" a b c
  IFS=. read -r a b c <<< "$cur"
  a=${a:-0}; b=${b:-0}; c=${c:-0}
  case "$kind" in
    major) echo "$((a+1)).0.0" ;;
    minor) echo "$a.$((b+1)).0" ;;
    *)     echo "$a.$b.$((c+1))" ;;
  esac
}

# release-notes: context = commits.txt meta.txt
heur_release_notes() {
  local out="$1"; shift
  local commits="" meta="" f
  for f in "$@"; do
    case "$f" in *commits*) commits="$f" ;; *meta*) meta="$f" ;; esac
  done
  [[ -n "$commits" && -s "$commits" ]] || { echo "::error::heur: нет контекста коммитов" >&2; return 1; }
  local current bump total n_break n_feat risk
  current="$(_heur_current_version "$meta")"
  total="$(grep -c . "$commits" 2>/dev/null || true)"; total="${total:-0}"
  n_break="$(grep -icE 'breaking change|!:' "$commits" 2>/dev/null || true)"
  n_feat="$(grep -icE '(^|:|\)) *feat([(:!]|$)' "$commits" 2>/dev/null || true)"
  if (( n_break > 0 )); then bump=major
  elif (( n_feat > 0 )); then bump=minor
  else bump=patch
  fi
  local version; version="$(_bump_version "$current" "$bump")"
  if [[ "$current" == "0.0.0" && "$bump" == "patch" ]]; then version="0.1.0"; bump=minor; fi
  if grep -qiE 'migrat|schema|breaking|terraform|helm|database' "$commits"; then
    risk=high
  elif grep -qiE 'infra|deploy|dockerfile|workflow|k8s|feat' "$commits"; then risk=medium
  else risk=low
  fi
  local breaking_json feats_json btxt ftxt
  btxt="$(grep -iE 'breaking|!:' "$commits" || true)"
  ftxt="$(grep -iE 'feat' "$commits" || true)"
  breaking_json="$(printf '%s' "$btxt" | jq -R -s 'split("\n") | map(select(length>0))')"
  feats_json="$(printf '%s' "$ftxt" | jq -R -s 'split("\n") | map(select(length>0))')"
  [[ -n "$breaking_json" ]] || breaking_json='[]'
  [[ -n "$feats_json" ]] || feats_json='[]'
  jq -n \
    --arg version "$version" --arg bump "$bump" --arg risk "$risk" \
    --arg notes "$(printf '# Release %s\n\nBump: **%s** (from %s), %s commit(s). Risk: %s.\n\n## Features\n%s\n\n## Breaking\n%s\n' \
      "$version" "$bump" "$current" "$total" "$risk" \
      "$(grep -iE 'feat' "$commits" | sed 's/^/- /' || true)" \
      "$(grep -iE 'breaking|!:' "$commits" | sed 's/^/- /' || true)")" \
    --argjson breaking "$breaking_json" --argjson feats "$feats_json" --arg total "$total" \
    '{backend:"heuristic", version:$version, bump:$bump, risk:$risk,
      notes:$notes, breaking:$breaking, summary:("heur: bump " + $bump + " from " + $total + " commits, risk=" + $risk)}' \
    > "$out"
}

# review: context = diff.patch
heur_review() {
  local out="$1"; shift
  local diff_file="$1"
  [[ -s "$diff_file" ]] || { echo "::error::heur: пустой дифф" >&2; return 1; }
  # только добавленные строки, исключая строки с самими паттернами (анти-FP)
  grep '^\+[^+]' "$diff_file" | grep -vE 'grep|pattern|EXAMPLE|registry\.example' > /tmp/heur_added.txt || true
  local blockers=() suggestions=()
  if grep -qE 'AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|xox[bap]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}' /tmp/heur_added.txt; then
    blockers+=("heur: похоже на секрет/токен в добавленных строках")
  fi
  if grep -qiE '(password|passwd|api_?key|secret)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9/+]{12,}' /tmp/heur_added.txt; then
    blockers+=("heur: возможен хардкод пароля/ключа")
  fi
  if grep -qE 'NODE_TLS_REJECT_UNAUTHORIZED[^0-9]*0|verify[[:space:]]*=[[:space:]]*False' /tmp/heur_added.txt; then
    blockers+=("heur: отключена проверка TLS")
  fi
  local lines; lines="$(wc -l < /tmp/heur_added.txt)"
  if (( lines > 1500 )); then
    suggestions+=("heur: крупный дифф ($lines добавл. строк) — рассмотреть разбиение")
  fi
  if grep -qE 'eval\(|rm -rf ' /tmp/heur_added.txt; then
    suggestions+=("heur: eval()/rm -rf в добавленном коде — проверить контекст")
  fi
  local risk verdict
  if (( ${#blockers[@]} > 0 )); then risk=high; verdict=block
  elif grep -qiE '^\+[[:space:]]*(BREAKING|migration)' /tmp/heur_added.txt; then risk=high; verdict=approve
  elif grep -qiE 'feat|endpoint|migration' /tmp/heur_added.txt; then risk=medium; verdict=approve
  else risk=low; verdict=approve
  fi
  local b_json s_json
  b_json="$(printf '%s\n' "${blockers[@]:-}" | jq -R -s 'split("\n") | map(select(length>0))')"
  s_json="$(printf '%s\n' "${suggestions[@]:-}" | jq -R -s 'split("\n") | map(select(length>0))')"
  jq -n --arg verdict "$verdict" --arg risk "$risk" --argjson blockers "$b_json" \
    --argjson suggestions "$s_json" --arg lines "$lines" \
    '{backend:"heuristic", verdict:$verdict, risk:$risk, blockers:$blockers,
      suggestions:$suggestions,
      summary:("heur: rule-based pre-review, " + $lines + " added lines (не LLM; полноценный ревью — AGENT_BACKEND=cli)")}' \
    > "$out"
}

# smoke: context = health-пробы
heur_smoke() {
  local out="$1"; shift
  local ctx="$1"
  [[ -s "$ctx" ]] || { echo "::error::heur: нет health-контекста" >&2; return 1; }
  local sum
  sum="$(grep -o 'summary ok=[0-9]*/[0-9]*' "$ctx" | tail -1)"
  sum="${sum:-summary ok=0/0}"
  local oks total bad
  oks="${sum#summary ok=}"; total="${oks#*/}"; oks="${oks%%/*}"
  bad="$(grep -cE 'status=5[0-9][0-9]|status=000' "$ctx" 2>/dev/null || true)"
  local verdict okflag
  if [[ "$oks" == "$total" && "$oks" != "0" && "$bad" == "0" ]]; then
    verdict=pass; okflag=true
  else
    verdict=block; okflag=false
  fi
  jq -n --arg verdict "$verdict" --argjson ok "$okflag" --arg sum "$sum" --arg bad "$bad" \
    '{backend:"heuristic", verdict:$verdict,
      checks:[{name:"health", ok:$ok, detail:($sum + ", 5xx/conn_fail=" + $bad)}],
      summary:("heur: " + $sum + ", 5xx/conn_fail=" + $bad)}' \
    > "$out"
}

# verify: context = пробы r1 + r2 (+metrics)
heur_verify() {
  local out="$1"; shift
  local ctx="$1"
  [[ -s "$ctx" ]] || { echo "::error::heur: нет контекста проб" >&2; return 1; }
  local probes=($(grep -oE 'status=[0-9]{3}' "$ctx" 2>/dev/null || true))
  local n=${#probes[@]}
  if (( n < 4 )); then
    jq -n --arg n "$n" '{backend:"heuristic", verdict:"escalate",
            reason:"heur: недостаточно проб для решения", evidence:[("probes=" + $n)], metrics:{}}' > "$out"
    return 0
  fi
  local half=$(( n / 2 ))
  local r1=("${probes[@]:0:$half}") r2=("${probes[@]:$half}")
  local bad1=0 bad2=0 good1=0 good2=0 p code
  for p in "${r1[@]}"; do code="${p#status=}"
    [[ "$code" == 2* ]] && good1=$((good1+1))
    [[ "$code" == 5* || "$code" == "000" ]] && bad1=$((bad1+1)); done
  for p in "${r2[@]}"; do code="${p#status=}"
    [[ "$code" == 2* ]] && good2=$((good2+1))
    [[ "$code" == 5* || "$code" == "000" ]] && bad2=$((bad2+1)); done
  local verdict reason
  if (( bad2 > 0 )); then
    verdict=rollback; reason="heur: деградация во 2-м раунде (bad=$bad2/${#r2[@]})"
  elif (( good1 == 0 && good2 == 0 )); then
    verdict=rollback; reason="heur: health не отвечает в обоих раундах"
  elif (( good2 == 0 )); then
    verdict=escalate; reason="heur: 2-й раунд без успешных проб — данных мало"
  else
    verdict=keep; reason="heur: оба раунда здоровы (r1 good=$good1/${#r1[@]}, r2 good=$good2/${#r2[@]})"
  fi
  jq -n --arg verdict "$verdict" --arg reason "$reason" \
    --arg r1 "good=$good1/${#r1[@]},bad=$bad1" --arg r2 "good=$good2/${#r2[@]},bad=$bad2" \
    '{backend:"heuristic", verdict:$verdict, reason:$reason,
      evidence:["round1 " + $r1, "round2 " + $r2],
      metrics:{round1:$r1, round2:$r2}}' > "$out"
}

call_heur() {
  # эвристики пишут сырой вывод в <out>.raw — extract_json перенесёт в <out>
  local raw="$1.raw"; shift
  case "$STAGE" in
    release-notes) heur_release_notes "$raw" "$@" ;;
    review)        heur_review "$raw" "$@" ;;
    smoke)         heur_smoke "$raw" "$@" ;;
    verify)        heur_verify "$raw" "$@" ;;
    *)
      echo "::error::heur: нет эвристики для стадии '$STAGE'" >&2
      return 1 ;;
  esac
}

MAX_ATTEMPTS="${AGENT_MAX_ATTEMPTS:-2}"
BACKEND="${AGENT_BACKEND:-cli}"
case "$BACKEND" in
  cli|heur|openai) ;;
  *) echo "::error::неизвестный AGENT_BACKEND '$BACKEND' (допустимо: openai, cli, heur)"; exit 1 ;;
esac
case "${AGENT_FALLBACK:-heur}" in
  heur|none) ;;
  *) echo "::error::неизвестный AGENT_FALLBACK '${AGENT_FALLBACK}' (допустимо: heur, none)"; exit 1 ;;
esac

# эвристики работают с исходными context-файлами, combined не нужен, но строим для cli
CONTEXT_FILES=("$@")
for f in "${CONTEXT_FILES[@]}"; do
  [[ -e "$f" ]] || { echo "::error::контекст-файл не найден: $f"; exit 1; }
done

attempt=1
no_key=0
while :; do
  echo "==> agent attempt $attempt/$MAX_ATTEMPTS (backend: $BACKEND, stage: $STAGE)"
  case "$BACKEND" in
    cli|openai)
      COMBINED="$(mktemp)"
      {
        echo "===== PROMPT ====="
        cat "$PROMPT_FILE"
        for f in "${CONTEXT_FILES[@]}"; do
          echo
          if [[ -s "$f" ]]; then
            echo "===== CONTEXT: $f ====="
            cat "$f"
          else
            echo "===== CONTEXT: $f (пусто/отсутствует) ====="
          fi
        done
      } > "$COMBINED"
      rc=0
      if [[ "$BACKEND" == "openai" ]]; then
        call_openai "$COMBINED" "$OUTPUT_FILE" || rc=$?
      else
        call_cli "$COMBINED" "$OUTPUT_FILE" || rc=$?
      fi
      rm -f "$COMBINED"
      if [[ "$BACKEND" == "openai" && "$rc" -eq 2 ]]; then
        no_key=1   # ключа нет — ретраи бессмысленны, сразу fallback
        break
      fi
      ;;
    heur) call_heur "$OUTPUT_FILE" "${CONTEXT_FILES[@]}" ;;
  esac
  if extract_json "$OUTPUT_FILE.raw" "$OUTPUT_FILE"; then
    if [[ "$BACKEND" == "openai" ]]; then
      # пометить вердикт фактическим бэкендом и моделью (аудит, симметрично heur)
      jq -c --arg model "${OPENAI_MODEL:-openrouter/free}" \
        '. + {backend:"model", model:$model}' "$OUTPUT_FILE" \
        > "$OUTPUT_FILE.tmp" && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
    fi
    echo "==> verdict OK"
    jq -c . "$OUTPUT_FILE"
    exit 0
  fi
  (( attempt >= MAX_ATTEMPTS )) && break
  attempt=$((attempt + 1))
done

# Fallback: LLM недоступен → детерминированные эвристики (или строгий fail-closed).
if [[ "$BACKEND" != "heur" && "${AGENT_FALLBACK:-heur}" != "none" ]]; then
  if [[ "$no_key" -eq 1 ]]; then
    echo "::notice::LLM ($BACKEND): ключ не задан — fallback на эвристики (heur)"
  else
    echo "::notice::LLM ($BACKEND) недоступен после $MAX_ATTEMPTS попыток — fallback на эвристики (heur)"
  fi
  call_heur "$OUTPUT_FILE" "${CONTEXT_FILES[@]}"
  if extract_json "$OUTPUT_FILE.raw" "$OUTPUT_FILE"; then
    echo "==> verdict OK (fallback: heur)"
    jq -c . "$OUTPUT_FILE"
    exit 0
  fi
fi

echo "::error::агент не вернул валидный JSON за $MAX_ATTEMPTS попыток; последние строки stderr:" >&2
tail -n 15 "$OUTPUT_FILE.err" >&2 2>/dev/null || true
exit 1
