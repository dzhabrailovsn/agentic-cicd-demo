#!/usr/bin/env bash
# Плейсхолдер деплоя. Fail-closed: без настроенной команды деплоя — падаем с подсказкой.
#
# Usage: bash deploy.sh <staging|production>
# Env:   DEPLOY_CMD — команда деплоя (из vars.DEPLOY_CMD_*), VERSION — версия/тег.
set -euo pipefail

ENVIRONMENT="${1:?usage: deploy.sh <staging|production>}"
VERSION="${VERSION:-unknown}"

if [[ -z "${DEPLOY_CMD:-}" ]]; then
  cat >&2 <<'EOF'
::error::DEPLOY_CMD не задан для этого окружения.

Настройте repo variable DEPLOY_CMD_STAGING / DEPLOY_CMD_PRODUCTION, например:

  # Docker:
  docker build -t registry.example.com/app:$VERSION . && docker push registry.example.com/app:$VERSION

  # CloudBase / Tencent (статик):
  tcb hosting deploy ./dist -e <ENV_ID>

  # Kubernetes:
  kubectl set image deployment/app app=registry.example.com/app:$VERSION

  # AWS ECS:
  aws ecs update-service --cluster prod --service app --force-new-deployment

Команда выполняется с env: VERSION, ENVIRONMENT. Облачные секреты держите в
OIDC-федерации (id-token: write) или environment secrets — не в DEPLOY_CMD.
EOF
  exit 1
fi

echo "==> deploy $VERSION -> $ENVIRONMENT"
export VERSION ENVIRONMENT
bash -c "$DEPLOY_CMD"
echo "==> deploy done"
