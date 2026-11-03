#!/usr/bin/env bash
# Блокирующий гейт по вердикту агента.
# Usage: bash gate.sh <verdict.json> <allowed1,allowed2,...>
# Пример: bash gate.sh verdict.json approve
set -euo pipefail

FILE="${1:?usage: gate.sh <verdict.json> <allowed,...>}"
ALLOWED="${2:?usage: gate.sh <verdict.json> <allowed,...>}"

[[ -s "$FILE" ]] || { echo "::error::файл вердикта пуст или отсутствует: $FILE"; exit 1; }

for key in verdict summary; do
  jq -e --arg k "$key" 'has($k)' "$FILE" >/dev/null \
    || { echo "::error::в вердикте нет обязательного поля '$key'"; exit 1; }
done

VERDICT="$(jq -r '.verdict // ""' "$FILE")"
case ",$ALLOWED," in
  *",$VERDICT,"*) ;;
  *) echo "::error::verdict '$VERDICT' не входит в разрешённые [$ALLOWED]"; exit 1 ;;
esac

echo "GATE OK: verdict=$VERDICT (allowed: $ALLOWED)"
