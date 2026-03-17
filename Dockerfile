# syntax=docker/dockerfile:1.19.0
FROM node:24-alpine3.21 AS ui-builder

ARG PROJECT=alloy
ARG VERSION=1.12.0

WORKDIR /ui

RUN set -eux \
    && apk add --no-cache git \
    && git clone -b v${VERSION} --single-branch --depth=1 https://github.com/grafana/alloy.git \
    && cp -a alloy/internal/web/ui/* /ui \
    && rm -rf alloy
RUN --mount=type=cache,target=/ui/node_modules,sharing=locked npm install \
    && npm run build


FROM golang:1.25-alpine3.21 AS go-builder

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG RELEASE_BUILD=1
ARG GOEXPERIMENT

ARG VERSION=1.12.0

WORKDIR /src/alloy

RUN set -eux \
    && apk add --no-cache binutils-gold bash gcc g++ make git binutils elogind-dev \
    && git clone -b v${VERSION} --single-branch --depth=1 https://github.com/grafana/alloy.git .

COPY --from=ui-builder /ui/dist /src/alloy/internal/web/ui/dist

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    GOOS="$TARGETOS" GOARCH="$TARGETARCH" GOARM=${TARGETVARIANT#v} \
    RELEASE_BUILD=${RELEASE_BUILD} VERSION=${VERSION} \
    GO_TAGS="netgo builtinassets promtail_journal_enabled" \
    GOEXPERIMENT=${GOEXPERIMENT} \
    make alloy

FROM alpine:3.21

ARG UID="473"
ARG USERNAME="alloy"

LABEL org.opencontainers.image.source="https://github.com/grafana/alloy"

RUN apk add --no-cache ca-certificates curl tzdata musl-utils

COPY --from=go-builder --chown=${UID}:${UID} /src/alloy/build/alloy /usr/local/bin/
COPY --from=go-builder --chown=${UID}:${UID} /src/alloy/example-config.alloy /etc/alloy/config.alloy
COPY docker-entrypoint.sh /usr/local/bin/

RUN set -x \
    && addgroup -S -g $UID $USERNAME \
    && adduser -S -u $UID -G $USERNAME $USERNAME \
    && mkdir -p /var/lib/alloy/data \
    && chown -R $USERNAME:$USERNAME /var/lib/alloy \
    && chmod -R 770 /var/lib/alloy

ENTRYPOINT ["docker-entrypoint.sh"]
ENV ALLOY_DEPLOY_MODE=docker
CMD ["alloy", "run", "/etc/alloy/config.alloy", "--storage.path=/var/lib/alloy/data"]