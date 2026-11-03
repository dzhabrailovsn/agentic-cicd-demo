# Демо-приложение для Container Apps (cloud.ru). Порт 8080 — как в официальном
# туториале cloud.ru (https://cloud.ru/docs/tutorials-evolution/list/topics/container-apps__ci-cd).
FROM node:20-alpine
WORKDIR /srv
COPY package.json package-lock.json server.js ./
ENV PORT=8080
EXPOSE 8080
CMD ["node", "server.js"]
