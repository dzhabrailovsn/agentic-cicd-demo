#!/usr/bin/env bash
# Деплой в Cloud.ru Evolution Container Apps: сборка + push образа в Artifact Registry.
# Официальный сценарий: https://cloud.ru/docs/tutorials-evolution/list/topics/container-apps__ci-cd
# Container App с включённой опцией «Автоматическое развертывание» сама создаёт
# новую ревизию, когда образ обновляется в реестре — ручных действий не нужно.
#
# Таргеты: пути образов app-staging / app-prod в одном реестре — Container Apps
# создаются из соответствующего образа (staging и prod обновляются независимо).
#
# Env (из GitHub):
#   CR_URI         реестр, напр. myrepo.cr.cloud.ru (repo variable EVO_CR_URI)
#   EVO_CR_LOGIN   логин персонального ключа доступа (secret)
#   EVO_CR_PWD     пароль персонального ключа доступа (secret)
#   VERSION        версия из релизного поезда (напр. v0.3.2)
#   ENVIRONMENT    staging | production (параметр)
set -euo pipefail

ENVIRONMENT="${1:?usage: deploy-cloudru.sh <staging|production>}"
VERSION="${VERSION:-unknown}"

: "${CR_URI:?(error) CR_URI не задан — добавьте repo variable EVO_CR_URI (напр. myrepo.cr.cloud.ru)}"
: "${EVO_CR_LOGIN:?(error) EVO_CR_LOGIN не задан — добавьте secret (персональный ключ доступа Artifact Registry)}"
: "${EVO_CR_PWD:?(error) EVO_CR_PWD не задан — добавьте secret}"

IMAGE="$CR_URI/app-$ENVIRONMENT"

echo "==> docker login $CR_URI"
echo "$EVO_CR_PWD" | docker login "$CR_URI" -u "$EVO_CR_LOGIN" --password-stdin

echo "==> build $IMAGE:$VERSION"
docker build -t "$IMAGE:$VERSION" -t "$IMAGE:latest" app/

echo "==> push (оба тега: $VERSION + latest)"
docker push "$IMAGE:$VERSION"
docker push "$IMAGE:latest"

echo "==> готово: $IMAGE:$VERSION в реестре."
echo "    Container App, созданная из образа $IMAGE с опцией «Автоматическое развертывание»,"
echo "    подхватит новый образ и выкатит ревизию автоматически."
