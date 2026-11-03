# Спека проекта: Агентский CI/CD «Релиз-менеджер» (Вариант 2)

| | |
|---|---|
| **Дата актуальности** | 2026-11-03 |
| **Состояние кода** | commit `a472398` (main), рабочее дерево чистое |
| **Инстанс** | `dzhabrailovsn/agentic-cicd-demo`, PRIVATE |
| **Источники** | локальный аудит (17 файлов, `bash -n`, прогон тестов) + GitHub API-снимок (`gh repo view`, `gh variable list`, `gh secret list`, `gh api …/environments`, `…/branches/main/protection`, `gh run list`) |
| **Статус системы** | 🔶 каркас развёрнут и работает fail-closed; сквозной деплой заблокирован находками A1–A5 (см. §8) |

---

## 1. Назначение и скоуп

Система автоматизирует доставку приложения в прод-клауд через GitHub Actions с
агентскими (LLM) гейтами. Принцип: **агент готовит, триггерит и проверяет;
прод-креды агенту не выдаются; все агентские решения — строгий JSON; гейты
fail-closed** (нет валидного вердикта → конвейер останавливается).

В скоупе: PR-ревью агентом, релизный поезд (версия → staging → smoke → prod →
verify), авто- и ручной rollback, аудит-артефакты. Вне скоупа: сам прод-клауд
(адаптируется через `DEPLOY_CMD_*`), канареечные раскатки (это Вариант 3), GitOps.

## 2. Сводка аудита (состояние на дату спеки)

| Компонент | Факт | Статус |
|---|---|---|
| Workflows (3 шт.) | `ci-review`, `release`, `rollback` — state `active` | ✅ |
| Shell-скрипты (4 шт.) | `agent.sh`, `gate.sh`, `deploy.sh`, `health.sh` — `bash -n` OK | ✅ |
| Демо-приложение | `app/` — lint/test/build зелёные локально (Node 24.16) | ✅ |
| JSON-схема вердиктов | `schema/verdict.schema.json` — валидный JSON | ✅ |
| Variables | `AGENT_CMD=zcode -p`, `AUTO_PROD_LOW_RISK=false` | ✅ установлены |
| Secrets | **пусто** (`AGENT_API_KEY` отсутствует) | 🔴 A1 |
| Environments | `staging`, `production`, `production-auto` созданы, `protection_rules=0` | 🔶 A3/A4 |
| Branch protection (main) | HTTP 403 «Upgrade to GitHub Pro or make public» | 🔶 A3 |
| Агентский CLI на раннере | не установлен (`zcode: command not found`) | 🔴 A1 |
| `DEPLOY_CMD_STAGING/PRODUCTION` | не заданы → `deploy.sh` падает fail-closed | 🔴 A2 |
| Health URLs (staging/prod) | не заданы → smoke/verify упадут | 🔴 A5 |
| Прогоны | 2 × Release train = failure на `release-prep` (8s/12s) — fail-closed сработал | ✅ ожидаемое |
| Releases/теги | нет (ни одного успешного релиза) | 🔶 следствие A1 |

## 3. Архитектура

```
PR ──► ci-review.yml: tests ──► agent-review (гейт approve)
merge в main ──► release.yml:
  release-prep (агент: notes/semver/risk; тег + GitHub Release)
    ──► deploy-staging (environment: staging)
    ──► smoke (агент-гейт pass)          ──fail──► Issue + стоп
    ──► prod-gate (environment: production; skip при risk=low ∧ AUTO_PROD_LOW_RISK=true)
    ──► deploy-prod-reviewed | deploy-prod-auto (environment: production[-auto])
    ──► verify (агент: keep/rollback/escalate)
           rollback ──► gh workflow run rollback.yml (предыдущий тег)
           escalate ──► Issue + стоп
rollback.yml: validate (тег существует) ──► rollback-deploy (production-auto)
             ──► post-verify (health)
```

**Concurrency-группы** (job-level, `cancel-in-progress: false`): `release-prep`,
`staging-deploy`, `production-deploy` (общая для deploy-prod-* и rollback-deploy).

**Матрица прав** (job-level permissions, least-privilege):

| Job | contents | прочее |
|---|---|---|
| tests | read | — |
| agent-review | read | pull-requests: write (комментарий) |
| release-prep | **write** (тег + Release) | — |
| deploy-staging / deploy-prod-* | read | id-token: write (OIDC) |
| smoke / verify | read | issues: write; verify + actions: write (dispatch rollback) |
| rollback-* | read | id-token: write (деплой); post-verify read |

Креды клауда существуют только внутри deploy-job'ов; агентские job'ы получают
только `AGENT_CMD`/`AGENT_API_KEY`.

## 4. Контракты

**Единый формат ответа агента** (`schema/verdict.schema.json`): объект с
обязательными `verdict` и `summary`; `verdict` по стадиям:

| Стадия | Допустимые verdict | Блокирует | Промпт |
|---|---|---|---|
| PR-ревью | `approve` \| `block` (+`risk`) | branch protection¹ | `prompts/review.md` |
| Релиз-план | — (структура: `version`,`bump`,`risk`,`notes`,`breaking`) | валидация jq | `prompts/release-notes.md` |
| Smoke | `pass` \| `block` | job exit 1 + Issue | `prompts/smoke.md` |
| Verify | `keep` \| `rollback` \| `escalate` | rollback→dispatch; escalate→Issue | `prompts/verify.md` |

¹ см. A3 — фактически сейчас не enforced.

**Обязательные правила контура:**
- `agent.sh`: `AGENT_CMD` обязателен (иначе `::error::` + exit 1); до
  `AGENT_MAX_ATTEMPTS` (2) попыток; извлечение JSON из prose/markdown-фенсов;
  fail-closed при отсутствии валидного JSON.
- `gate.sh <file> <allowed,…>`: fail, если файл пуст, нет `verdict`/`summary`,
  или verdict вне белого списка.
- `deploy.sh`: fail-closed без `DEPLOY_CMD`; команда получает `env VERSION`,
  `ENVIRONMENT`; облачные секреты — через OIDC/environment secrets, не в переменной.
- `health.sh`: N проб, строки `probe=i status=… latency=…` + фрагменты тел 2xx;
  exit 1 при 0 успешных.
- `verify`: rollback только на `previous_tag` (пусто у первого релиза → fail-closed);
  данные недостаточны → `escalate`, не угадывать.

## 5. Конфигурация (фактическое состояние)

| Имя | Тип | Требуемое значение | Факт |
|---|---|---|---|
| `AGENT_CMD` | variable | headless-команда агента | ✅ `zcode -p` |
| `AUTO_PROD_LOW_RISK` | variable | `true`/`false` | ✅ `false` |
| `AGENT_API_KEY` | secret | ключ API агента | ❌ отсутствует |
| `STAGING_HEALTH_URL` | variable | health-endpoint staging | ❌ не задан |
| `PROD_HEALTH_URL` | variable | health-endpoint prod | ❌ не задан |
| `DEPLOY_CMD_STAGING` | variable | команда деплоя staging | ❌ не задана |
| `DEPLOY_CMD_PRODUCTION` | variable | команда деплоя прод | ❌ не задана |

Environments: `staging` (без защиты), `production` (замысел: required reviewer
`dzhabrailovsn` + wait timer), `production-auto` (без reviewers — для low-risk
и rollback). Фактически у всех `protection_rules=0` — см. A3/A4.

## 6. Функциональные требования

- **RF-1** PR-гейт: tests + агентское ревью; block/фейл агента запрещает мерж.
- **RF-2** Merge в main → автоматический релизный поезд; ровно один поезд за раз
  (concurrency); дубль тега → fail.
- **RF-3** Релиз-план агентом: semver по conventional commits, release notes, risk.
- **RF-4** Staging-деплой, затем smoke-гейт по health-пробам.
- **RF-5** Прод-гейт: ручное одобрение для risk≠low; авто для risk=low при
  включённом `AUTO_PROD_LOW_RISK=true` (environment `production-auto`).
- **RF-6** Пост-деплой верификация (2 раунда + soak 60 с): keep/rollback/escalate.
- **RF-7** Rollback: автоматический (verify) и ручной (`workflow_dispatch` с
  `tag`+`reason`), с валидацией тега и пост-проверкой health.
- **RF-8** Эскалация: Issue с логами/вердиктом при smoke/verify-фейлах.

## 7. Нефункциональные требования

- **NFR-1 Fail-closed**: отсутствие валидного JSON, пустой `DEPLOY_CMD`, первый
  релиз без previous_tag — всегда остановка, никогда «молча проехать».
- **NFR-2 Least-privilege**: см. матрицу §3; OIDC вместо статических ключей.
- **NFR-3 Аудит**: сырые вердикты — артефакты каждого рана (`release-plan`,
  `smoke-verdict`, `verify-verdict`, `agent-verdict`).
- **NFR-4 Изоляция секретов**: агентские и облачные секреты не пересекаются.
- **NFR-5 Детерминированность**: решение об остановке принимает скрипт
  (`gate.sh`/exit-code), модель — только рекомендация в JSON.

## 8. Находки аудита

| ID | Приоритет | Находка | Рекомендация |
|---|---|---|---|
| **A1** | 🔴 P0 (блокер) | Секрет `AGENT_API_KEY` отсутствует; агентский CLI не установлен на раннере → каждый Release train падает на `release-prep` (подтверждено ранами 41671637749, 41672117755). Дополнительно: пакет `zcode` может быть недоступен из публичного npm — тогда сменить `AGENT_CMD` (например `claude -p` + `@anthropic-ai/claude-code`). | Установить публичный headless-CLI в шагах `Install agent CLI`; добавить secret `AGENT_API_KEY`; при необходимости поправить `AGENT_CMD` |
| **A2** | 🔴 P0 (блокер) | `DEPLOY_CMD_STAGING/PRODUCTION` не заданы → деплой падает fail-closed (подсказка в stderr `deploy.sh`) | Задать команды под реальный клауд (примеры в сообщении ошибки) |
| **A3** | 🔶 P1 (лимит плана) | Branch protection на main недоступен: HTTP 403 (free + PRIVATE). Required checks `tests`/`agent-review` не enforced — PR можно смержить мимо ревью | GitHub Pro/Team или переключить репо в public; затем PUT из README §«Включение branch protection» |
| **A4** | 🔶 P1 (лимит плана) | Environment protection rules не применились: HTTP 422 «billing plan does not support required reviewers» → `prod-gate` не ждёт одобрения и проходит мгновенно. **Фактически сейчас прод-деплой автоматический для любого risk, несмотря на `AUTO_PROD_LOW_RISK=false`** | Та же причина/решение, что A3. До этого момента единственный барьер перед продом — smoke + A2 |
| **A5** | 🔴 P1 | `STAGING_HEALTH_URL`/`PROD_HEALTH_URL` не заданы → smoke/verify упадут (после снятия A1/A2) | Задать URL после первого успешного деплоя |
| **A6** | 🟡 P2 | `npm install` вместо `npm ci`, нет `package-lock.json` → невоспроизводимые сборки | Сгенерировать lockfile, вернуть `npm ci` |
| **A7** | 🟡 P2 | `rollback.yml` берёт `scripts/`/`health.sh` из checkout старого тега — поломка скриптов в прошлом релизе ломает откат | Брать скрипты из main (отдельный checkout `ref: main` для шагов верификации) |
| **A8** | 🟡 P2 | `deploy.sh` исполняет `bash -c "$DEPLOY_CMD"` из repo variable — доверенная зона админа репо; менять variables может только admin (приемлемо, задокументировать) | Оставить; не класть туда секреты (см. README ⚠) |
| **A9** | 🟢 P3 | `scripts/metrics.sh` отсутствует — verify видит только health-пробы (по дизайну) | Добавить read-only хук метрик для зрелого verify |
| **A10** | 🟢 P3 | Git на Windows даёт CRLF-предупреждения; теоретический риск поломки LF-скриптов при повторном чекауте | Добавлен `.gitattributes` (в этом же коммите): `*.sh`, `*.yml` — `eol=lf` |

## 9. Definition of Done (перевод системы в рабочее состояние)

- **D1** (снимает A1): секрет + CLI установлены; тест-PR показывает
  `agent-review → approve` и комментарий агента.
- **D2** (снимает A2): merge → тег + GitHub Release + успешный `deploy-staging`.
- **D3** (снимает A5): `smoke → pass` на реальном staging.
- **D4** (снимает A3/A4): branch protection активен; prod-gate реально ждёт
  Approve (наблюдаемо «Review pending … production»).
- **D5**: первый полный релиз с `verify → keep`; репетиция `rollback.yml` на
  демо-окружении.

## 10. Эксплуатация

- Ручной откат: `gh workflow run rollback.yml -f tag=vX.Y.Z -f reason="…"`.
- Аудит прогона: Actions → ран → артефакты `*-verdict`/`release-plan`.
- Отключить авто-прод полностью: держать `AUTO_PROD_LOW_RISK=false` (после
  включения protection rules из D4).
- Замена стека: правка job `tests` (ci-review.yml) и `DEPLOY_CMD_*`.

## 11. Известные ограничения (принятые компромиссы)

1. Вердикт агента — вероятностный: единственный жёсткий барьер — скриптовые
   гейты; модель может лишь вернуть `block`/`rollback` (см. NFR-5).
2. Роллбэк первый релиз сделать не может (нет previous_tag) — fail-closed.
3. Канарейные раскатки и метрики — вне скоупа Варианта 2 (A9 — точка расширения).
4. Enforcement-гейты зависят от тарифного плана GitHub (A3/A4).

---

### Приложение: снимки аудита

- Runs: `41671637749` (8s, failure, 16:11:37Z), `41672117755` (12s, failure,
  16:14:22Z) — обе на шаге `release-prep / Agent: release plan`; первая с
  «AGENT_CMD не задан» (variable выставлен через 33 с после пуша), вторая —
  `zcode -p: command not found` при 2 попытках.
- `gh api …/environments` → `production/staging/production-auto`,
  `protection_rules: 0` у всех (2026-11-03T16:12–16:15Z).
- `gh api …/branches/main/protection` → `403` (2026-11-03).
- Теги/релизы: отсутствуют на момент спеки.
