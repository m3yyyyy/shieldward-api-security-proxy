# syntax=docker/dockerfile:1.20

FROM node:24.20.0-alpine3.24@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf AS build

WORKDIR /build

COPY edge/package.json edge/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci

COPY edge/tsconfig.json ./
COPY edge/src ./src

RUN npm run build
RUN npm prune --omit=dev

FROM node:24.20.0-alpine3.24@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf AS runtime

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
  CMD ["node", "-e", "fetch(process.env.SHIELDWARD_HEALTHCHECK_URL,{signal:AbortSignal.timeout(3000)}).then((response)=>{if(!response.ok)process.exit(1)}).catch(()=>process.exit(1))"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["node", "dist/index.js"]
