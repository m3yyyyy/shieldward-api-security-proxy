# syntax=docker/dockerfile:1.20

FROM golang:1.27.1-alpine3.24@sha256:cf6fca6641884b8433441b2b0652976f975e1d0fdd26d177eaaf8596087f3125 AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY cmd ./cmd
COPY internal ./internal

RUN mkdir -p /rootfs/usr/local/bin

ARG VERSION=0.1.0-dev
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build \
      -trimpath \
      -buildvcs=false \
      -ldflags="-s -w -buildid= -X main.version=${VERSION}" \
      -o /rootfs/usr/local/bin/shieldwardd \
      ./cmd/shieldwardd

RUN mkdir -p \
      /rootfs/etc/shieldward \
      /rootfs/etc/ssl/certs \
      /rootfs/run/secrets \
    && cp /etc/ssl/certs/ca-certificates.crt \
      /rootfs/etc/ssl/certs/ca-certificates.crt

FROM scratch AS runtime

ARG VERSION=0.1.0-dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="ShieldWard control plane" \
      org.opencontainers.image.description="Signed policy control plane for ShieldWard" \
      org.opencontainers.image.source="https://github.com/m3yyyyy/shieldward-api-security-proxy" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

COPY --from=build --chown=65532:65532 /rootfs/ /

USER 65532:65532
EXPOSE 18080

ENV SHIELDWARD_HEALTHCHECK_URL="http://127.0.0.1:18080/readyz"

HEALTHCHECK --interval=10s --timeout=4s --start-period=10s --retries=6 \
  CMD ["/usr/local/bin/shieldwardd", "probe"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/shieldwardd"]
CMD ["help"]
