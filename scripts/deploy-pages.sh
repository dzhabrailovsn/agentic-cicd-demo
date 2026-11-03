#!/usr/bin/env bash
# Деплой веб-морды релиза на GitHub Pages (ветка gh-pages) — публичный прод.
# В каталоге должен быть checkout ТОЙ версии, которую деплоим (main или тег).
#
# Важно: на gh-pages коммитятся ТОЛЬКО index.html и health.json (не `git add -A`),
# иначе скрипт при往返-переключении веток удалит сам себя (tracked в gh-pages,
# не tracked в main). См. инцидент релиза v0.5.0.
#
# Env: VERSION — версия релиза (напр. v0.4.0).
set -euo pipefail

VERSION="${VERSION:-dev}"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CUR="$(git rev-parse --abbrev-ref HEAD)"

git fetch origin gh-pages 2>/dev/null || true
if git rev-parse -q --verify origin/gh-pages >/dev/null 2>&1; then
  git checkout -q -B gh-pages origin/gh-pages
  EXISTS=1
else
  git checkout -q --orphan gh-pages
  git rm -rqf . 2>/dev/null || true
  EXISTS=0
fi

cat > index.html <<HTML
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>agentic-cicd demo — ${VERSION}</title>
<style>
 body{font-family:system-ui,sans-serif;background:#0d1117;color:#e6edf3;display:flex;
      min-height:100vh;align-items:center;justify-content:center;margin:0}
 .card{max-width:560px;padding:2.5rem;border:1px solid #30363d;border-radius:12px;text-align:center}
 .ok{color:#3fb950;font-size:2rem} code{background:#161b22;padding:.2em .4em;border-radius:6px}
 a{color:#58a6ff} .muted{color:#8b949e;font-size:.85rem}
</style></head>
<body><div class="card">
 <div class="ok">● ok</div>
 <h1>Release ${VERSION}</h1>
 <p>Задеплоено агентским конвейером (release train → prod gate → verify).</p>
 <p><a href="health.json">health.json</a> · <a href="https://github.com/dzhabrailovsn/agentic-cicd-demo">репозиторий</a></p>
 <p class="muted">deployed at ${STAMP} · target: GitHub Pages (gh-pages)</p>
</div></body></html>
HTML

printf '{"status":"ok","version":"%s","deployed_at":"%s"}\n' "$VERSION" "$STAMP" > health.json

git add index.html health.json

# на раннере identity не задан — задаём repo-local
git config user.name  "${GIT_AUTHOR_NAME:-release-bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-actions@github.com}"

if git diff --cached --quiet; then
  echo "контент не изменился — пуш не нужен"
else
  git commit -qm "deploy ${VERSION} (release train)"
  git push origin gh-pages
  echo "==> ${VERSION} задеплоена на GitHub Pages (gh-pages)"
fi

if [[ "$EXISTS" == "1" ]]; then
  git checkout -q "$CUR" 2>/dev/null || true
fi
