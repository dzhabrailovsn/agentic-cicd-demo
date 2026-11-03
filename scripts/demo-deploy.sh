#!/usr/bin/env bash
# DEMO-деплой: поднимает релизный артефакт локально на раннере и проверяет его health.
#
# ЭТО НЕ ПРОД-КЛАУД. Это заглушка-таргет, чтобы конвейер шёл end-to-end до выбора
# реального клауда: job собирает/запускает артефакт, дергает /health и завершается.
# Как появится реальный клауд — замените repo variables DEPLOY_CMD_STAGING /
# DEPLOY_CMD_PRODUCTION на настоящую команду (примеры в scripts/deploy.sh).
#
# Usage (через DEPLOY_CMD_*): bash scripts/demo-deploy.sh <staging|production>
# Env: VERSION — деплоимая версия.
set -euo pipefail

ENVIRONMENT="${1:?usage: demo-deploy.sh <staging|production>}"
PORT="${DEMO_PORT:-3000}"
VERSION="${VERSION:-unknown}"

echo "==> [DEMO] deploy $VERSION -> $ENVIRONMENT (локально на раннере, порт $PORT)"
node --version

PORT="$PORT" node app/server.js &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; }
trap cleanup EXIT

ok=""
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"status":"ok"'; then
    ok=1; break
  fi
  sleep 0.5
done

if [[ -z "$ok" ]]; then
  echo "::error::[DEMO] сервер не поднялся на порту $PORT" >&2
  cat /tmp/demo_srv.log 2>/dev/null >&2 || true
  exit 1
fi

echo "==> [DEMO] health OK: $(curl -fsS "http://127.0.0.1:$PORT/health")"
echo "==> [DEMO] deploy done ($ENVIRONMENT)"
