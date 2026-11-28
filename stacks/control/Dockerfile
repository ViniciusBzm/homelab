# HomeLab Control - imagem de producao (multi-stage). Contexto de build: RAIZ do repositorio.
#   docker build -f stacks/control/Dockerfile --build-arg NODE_IMAGE=node:<versao-fixa>-alpine -t homelab-control:<commit> .
# A imagem final contem so: node (runtime), dependencias de producao, server.mjs e o front compilado.
# Sem npm/npx/corepack/yarn, sem tsx/esbuild/vite/vitest/playwright, sem fixtures nem codigo-fonte.
ARG NODE_IMAGE

# ---------- 1) build: dependencias completas + compilacao do front e empacotamento da API
FROM ${NODE_IMAGE} AS build
WORKDIR /src
COPY package.json package-lock.json ./
COPY packages/contracts/package.json packages/contracts/
COPY apps/control-api/package.json apps/control-api/
COPY apps/control-web/package.json apps/control-web/
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY tsconfig.json ./
COPY packages/contracts/src packages/contracts/src
COPY apps/control-api/src apps/control-api/src
COPY apps/control-api/build.mjs apps/control-api/
COPY apps/control-web/index.html apps/control-web/vite.config.ts apps/control-web/
COPY apps/control-web/src apps/control-web/src
COPY apps/control-web/public apps/control-web/public
RUN npm run build -w @homelab/control-web && npm run build -w @homelab/control-api

# ---------- 2) dependencias de producao da API (fastify, @fastify/static, zod)
FROM ${NODE_IMAGE} AS prod-deps
WORKDIR /src
COPY package.json package-lock.json ./
COPY packages/contracts/package.json packages/contracts/
COPY apps/control-api/package.json apps/control-api/
COPY apps/control-web/package.json apps/control-web/
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund -w @homelab/control-api \
 && rm -rf node_modules/@homelab node_modules/.bin

# ---------- 3) runtime
FROM ${NODE_IMAGE} AS runtime
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn-* \
           /usr/local/bin/yarn /usr/local/bin/yarnpkg
ENV NODE_ENV=production \
    HL_CONTROL_HOST=0.0.0.0 \
    HL_CONTROL_PORT=8088 \
    HL_CONTROL_WEB_DIR=/app/web
WORKDIR /app
COPY --from=prod-deps --chown=root:root /src/node_modules ./node_modules
COPY --from=build --chown=root:root /src/apps/control-api/dist/server.mjs ./server.mjs
COPY --from=build --chown=root:root /src/apps/control-web/dist ./web
USER node
EXPOSE 8088
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:8088/api/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]
CMD ["node", "server.mjs"]
