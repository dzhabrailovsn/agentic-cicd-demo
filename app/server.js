// Демо-приложение для прогона конвейера (PR-тест агент-ревью). Замените на своё — стадия tests в
// ci-review.yml выполняется в каталоге app/ (под свой стек поправьте job).
const http = require('node:http');

function healthPayload() {
  return { status: 'ok', uptime: process.uptime() };
}

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(healthPayload()));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('agentic-cicd demo app\n');
});

if (require.main === module) {
  const port = process.env.PORT || 3000;
  server.listen(port, () => console.log(`listening on :${port}`));
}

module.exports = { healthPayload, server };
