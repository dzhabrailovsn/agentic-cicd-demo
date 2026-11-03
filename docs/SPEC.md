# Спека проекта: Агентский CI/CD «Релиз-менеджер» (Вариант 2)

| | |
|---|---|
| **Дата актуальности** | 2026-11-03 · **ревизия 2** |
| **Состояние кода** | main, «blocker fixes» (этот коммит); ревизия 1 — `a472398` |
| **Инстанс** | `dzhabrailovsn/agentic-cicd-demo`, PRIVATE |
| **Источники** | аудит рев. 1 + живые прогоны Actions: `41680931868` (fail: gh-models), `41682567346` (fail: честный smoke-block), `41683321364` (**success end-to-end**) |
| **Статус системы** | ✅ конвейер работает end-to-end в demo-режиме: релиз **v0.1.1** прошёл release→staging→smoke→prod→verify(keep), ран `41683321364`. Осталось: enforcement-гейты (A3/A4, тариф), реальный прод-клауд (A11), LLM-агент (A1-note) |

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
| Variables | `AGENT_BACKEND=heur`, `AGENT_CMD=zcode -p` (резерв для cli), `AUTO_PROD_LOW_RISK=false`, `DEPLOY_CMD_*=bash scripts/demo-deploy.sh …` | ✅ установлены |
| Secrets | пусто — и для бэкенда `heur` **не требуются** (для LLM `cli` понадобится `AGENT_API_KEY`) | ✅ |
| Environments | `staging`, `production`, `production-auto` созданы, `protection_rules=0` | 🔶 A3/A4 |
| Branch protection (main) | HTTP 403 «Upgrade to GitHub Pro or make public» | 🔶 A3 |
| Агентский бэкенд | `heur` — детерминированные эвристики (7 локальных тест-кейсов ✅ + живые вердикты в ране). GitHub Models **retired 2026-07-30** (API отвечает заглушкой `OK`) — gh-models путь удалён; `cli` сохранён для LLM | ✅ / LLM-опция (A1-note) |
| `DEPLOY_CMD_STAGING/PRODUCTION` | установлены → `demo-deploy.sh`: поднимает артефакт на раннере и проверяет /health | 🔶 A11 (не реальный клауд) |
| Health URLs (staging/prod) | не заданы → smoke/verify работают в DEMO-режиме (артефакт поднимается в job, реальный URL — при задании переменной) | 🔶 A11 |
| Прогоны | 4 рана Release train: 2 fail-closed (gh-models «OK»; AGENT_CMD до установки переменных), 1 честный smoke-block (`summary ok=1/5` — баг A12), 1 **success** end-to-end (`41683321364`) | ✅ |
| Releases/теги | `v0.1.0`, `v0.1.1` (Latest) — notes сгенерированы агент-стадией | ✅ |

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
| `AGENT_BACKEND` | variable | бэкенд агента: `heur` (эвристики) или `cli` (LLM) | ✅ `heur` |
| `AGENT_CMD` | variable | headless-команда агента (backend=`cli`) | ✅ `zcode -p` (резерв) |
| `AUTO_PROD_LOW_RISK` | variable | `true`/`false` | ✅ `false` |
| `GH_MODEL` | variable | удалена вместе с retired GitHub Models | — |
| `AGENT_API_KEY` | secret | ключ API агента (backend=`cli`) | ❌ отсутствует (не нужен для `heur`) |
| `STAGING_HEALTH_URL` | variable | health-endpoint staging | ❌ не задан → DEMO-режим smoke |
| `PROD_HEALTH_URL` | variable | health-endpoint прод | ❌ не задан → DEMO-режим verify |
| `DEPLOY_CMD_STAGING` | variable | команда деплоя (получает `env VERSION`) | ✅ `bash scripts/demo-deploy.sh staging` |
| `DEPLOY_CMD_PRODUCTION` | variable | команда деплоя прод | ✅ `bash scripts/demo-deploy.sh production` |

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
| **A1** | ✅ ЗАКРЫТО (рев. 2) | Первопричина вскрылась глубже: **GitHub Models полностью retired 2026-07-30** (docs; `models.github.ai` отвечает заглушкой `OK`, ран `41680931868`). Реализован бэкенд **`heur`** — детерминированные эвристики по тем же JSON-контрактам (7 локальных тест-кейсов + живые вердикты в `41683321364`). `AGENT_API_KEY`/CLI больше не блокеры; путь `cli` сохранён для полноценного LLM | Для LLM-ревью: `AGENT_BACKEND=cli` + шаг `Install agent CLI` + secret `AGENT_API_KEY` |
| **A2** | 🔶 → **A11** | `DEPLOY_CMD_*` установлены, но указывают на `demo-deploy.sh` (артефакт поднимается на раннере, /health проверяется — конвейер зелёный; реальный клауд не задействован) | См. новую A11 |
| **A3** | 🔶 P1 (лимит плана) | Branch protection на main недоступен: HTTP 403 (free + PRIVATE). Required checks `tests`/`agent-review` не enforced — PR можно смержить мимо ревью | GitHub Pro/Team или переключить репо в public; затем PUT из README §«Включение branch protection» |
| **A4** | 🔶 P1 (лимит плана) | Environment protection rules не применились: HTTP 422 «billing plan does not support required reviewers» → `prod-gate` не ждёт одобрения и проходит мгновенно. **Фактически сейчас прод-деплой автоматический для любого risk, несмотря на `AUTO_PROD_LOW_RISK=false`** | Та же причина/решение, что A3. До этого момента единственный барьер перед продом — smoke + A2 |
| **A5** | ✅ ЗАКРЫТО (рев. 2) | URL не заданы → добавлен **DEMO-режим** smoke/verify: при пустой переменной job сам поднимает релизный артефакт (порты 3001/3002) и проверяет его; при задании URL автоматически включается real-режим | Задать URL вместе с A11 |
| **A6** | 🟡 P2 | `npm install` вместо `npm ci`, нет `package-lock.json` → невоспроизводимые сборки | Сгенерировать lockfile, вернуть `npm ci` |
| **A7** | 🟡 P2 | `rollback.yml` берёт `scripts/`/`health.sh` из checkout старого тега — поломка скриптов в прошлом релизе ломает откат | Брать скрипты из main (отдельный checkout `ref: main` для шагов верификации) |
| **A8** | 🟡 P2 | `deploy.sh` исполняет `bash -c "$DEPLOY_CMD"` из repo variable — доверенная зона админа репо; менять variables может только admin (приемлемо, задокументировать) | Оставить; не класть туда секреты (см. README ⚠) |
| **A9** | 🟢 P3 | `scripts/metrics.sh` отсутствует — verify видит только health-пробы (по дизайну) | Добавить read-only хук метрик для зрелого verify |
| **A10** | 🟢 P3 | Git на Windows даёт CRLF-предупреждения; теоретический риск поломки LF-скриптов при повторном чекауте | Добавлен `.gitattributes` (в этом же коммите): `*.sh`, `*.yml` — `eol=lf` |
| **A11** | 🔶 P1 (новое, рев. 2) | Деплой-таргет — demo-заглушка на раннере: «прод» — одноразовый процесс внутри job'а, состояние не сохраняется между джобами | Подключить реальный клауд: OIDC + настоящие `DEPLOY_CMD_*` + health URLs |
| **A12** | ✅ ЗАКРЫТО (рев. 2) | `health.sh`: `for i in "$(seq …)"` (заквочено) выполнял **одну** пробу вместо N → `summary ok=1/5` → честный false-block смока (ран `41682567346`). Побочно найдено: `jq -R -s` на пустом вводе выдаёт пустоту (ломало `--argjson` эвристик) | Исправлено: цикл без кавычек; эвристики защищены от пустого ввода; проверено локально на живом сервере (ok=5/5) |

## 9. Definition of Done (перевод системы в рабочее состояние)

- **D1** ✅ (рев. 2, бэкенд `heur`): агентские вердикты в живом ране `41683321364`; LLM-вариант — после ключа (A1-note).
- **D2** ✅ (рев. 2): `v0.1.1` — тег + GitHub Release + успешный `deploy-staging` (demo-таргет).
- **D3** ✅ (рев. 2, DEMO-режим): `smoke → pass`, `summary ok=5/5`; real-режим — вместе с A11.
- **D4** ⬜ — тариф/видимость репо (A3/A4).
- **D5** 🔶: `verify → keep` подтверждён (ран `41683321364`); репетиция ручного rollback не проводилась (пара `v0.1.0` → `v0.1.1` готова для теста: `gh workflow run rollback.yml -f tag=v0.1.0`).

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
5. Бэкенд `heur` — rule-based, **не LLM**: ревью диффа поверхностное
   (секреты/TLS/паттерны), release-notes механические. Содержательный анализ —
   путь `cli` (A1-note). Все вердикты помечены `"backend":"heuristic"` для аудита.

---

### Приложение: снимки аудита

- Ревизия 1: `41671637749` (8s, fail — «AGENT_CMD не задан»), `41672117755`
  (12s, fail — `zcode -p: command not found`); `gh api …/environments` →
  `protection_rules: 0` у всех; branch protection → `403`; теги/релизы: нет.
- Ревизия 2: `41680931868` fail — «GitHub Models вернул ошибку: OK» (сервис
  retired 2026-07-30); `41682567346` — release-prep ✓ (v0.1.0), staging ✓,
  smoke честно blocked `summary ok=1/5` (баг A12); `41683321364` — **success**:
  `{"backend":"heuristic","version":"0.1.1","bump":"patch","risk":"low"}` →
  smoke `pass 5/5` → prod-gate → deploy-prod → verify `keep (r1 3/3, r2 3/3)`.
  Релизы: `v0.1.0`, `v0.1.1` (Latest).
