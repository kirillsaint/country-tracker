FROM node:24-alpine AS build
WORKDIR /app
# corepack ставит ровно ту версию pnpm, что в package.json -> packageManager, без интерактивного вопроса
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY tsconfig.json ./
COPY src ./src
RUN pnpm build && pnpm prune --prod

# админка в браузере (React) — собирается отдельно и кладётся рядом с сервером
FROM node:24-alpine AS admin
WORKDIR /app/admin
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable
COPY admin/package.json admin/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY admin ./
RUN pnpm build

FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production
ENV ADMIN_DIST=/app/admin
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=admin /app/admin/dist ./admin
COPY package.json ./
EXPOSE 3000
USER node
CMD ["node", "dist/index.js"]
