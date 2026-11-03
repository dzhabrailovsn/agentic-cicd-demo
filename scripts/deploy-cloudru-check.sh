#!/usr/bin/env bash
# Проверка готовности cloud.ru-деплоя + локальная сборка образа (без push).
# Usage: bash deploy-cloudru-check.sh
set -euo pipefail

echo "== 1. Docker доступен? =="
docker --version || { echo "::error::docker не найден"; exit 1; }

echo "== 2. Dockerfile на месте? =="
[[ -f app/Dockerfile ]] && echo "OK: app/Dockerfile" || { echo "::error::нет app/Dockerfile"; exit 1; }

echo "== 3. Локальная сборка образа =="
docker build -t agentic-cicd-check:local app/ && echo "OK: образ собрался"

echo "== 4. Проверка, что в контейнере отвечает /health =="
CID="$(docker run -d -p 18080:8080 agentic-cicd-check:local)"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:18080/health 2>/dev/null | grep -q '"status":"ok"'; then
    echo "OK: /health в контейнере отвечает"; exit 0
  fi
  sleep 0.5
done
echo "::error::контейнер не ответил на /health"; exit 1
