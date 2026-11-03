#!/usr/bin/env bash
# Read-only хук метрик для стадии verify (A9).
#
# Задайте repo variable METRICS_URL — endpoint, отдающий текст/JSON метрик
# (Prometheus /metrics, ваш обёрточный API к CloudWatch и т.п.). Скрипт только
# читает; агрегация/оценка — работа агента verify.
#
# Env: METRICS_URL — URL метрик (опционально; без него выводится notice).
set -euo pipefail

URL="${METRICS_URL:-}"

if [[ -z "$URL" ]]; then
  echo "(METRICS_URL не задан — метрики недоступны; verify ориентируется на health-пробы)"
  exit 0
fi

echo "== metrics from $URL =="
# читаем только первые 2КБ — контекст для агента, не выгрузка
curl -fsS --max-time 15 "$URL" | head -c 2048 || {
  echo "::warning::METRICS_URL недоступен (это не фейлит verify — агент учтёт отсутствие данных)"
}
