# syntax=docker/dockerfile:1.20

FROM node:26.8.1-alpine3.24@sha256:2d984a15c9b54fd0aeb608b8e0d0d83529eb34d2966db27a1fb4f1edc3d298a3 AS build

WORKDIR /build

COPY edge/package.json edge/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci

COPY edge/tsconfig.json ./
COPY edge/src ./src

RUN npm run build
RUN npm prune --omit=dev

FROM node:26.8.1-alpine3.24@sha256:2d984a15c9b54fd0aeb608b8e0d0d83529eb34d2966db27a1fb4f1edc3d298a3 AS runtime

RUN apk upgrade --no-cache \
    && rm -rf \
      /root/.npm \
      /usr/local/bin/corepack \
      /usr/local/bin/node-gyp \
      /usr/local/bin/npm \
      /usr/local/bin/npx \
      /usr/local/lib/node_modules/corepack \
      /usr/local/lib/node_modules/npm

ARG VERSION=0.1.0-dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="ShieldWard edge" \
      org.opencontainers.image.description="Fail-closed API security gateway for ShieldWard" \
      org.opencontainers.image.source="https://github.com/m3yyyyy/shieldward-api-security-proxy" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

ENV NODE_ENV="production" \
    SHIELDWARD_HEALTHCHECK_URL="http://127.0.0.1:8787/readyz"

WORKDIR /app

COPY --from=build --chown=1000:1000 /build/package.json /build/package-lock.json ./
COPY --from=build --chown=1000:1000 /build/node_modules ./node_modules
COPY --from=build --chown=1000:1000 /build/dist ./dist

USER 1000:1000
EXPOSE 8787

HEALTHCHECK --interval=10s --timeout=4s --start-period=15s --retries=6 \
  CMD ["node", "dist/healthcheck.js"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["node", "dist/index.js"]
