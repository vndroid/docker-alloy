# syntax=docker/dockerfile:1.19.0
FROM node:24-alpine3.23 AS ui-builder

ARG PROJECT=alloy
ARG VERSION=1.13.0

RUN set -eux \
    && apk add --no-cache git \
    && addgroup -g 1001 gorelease \
    && adduser -D -u 1001 -G gorelease gorelease

USER 1001:1001

WORKDIR /ui

RUN set -eux \
    && git clone -b v${VERSION} --single-branch --depth=1 https://github.com/grafana/alloy.git \
    && cp -a alloy/internal/web/ui/* /ui \
    && rm -rf alloy \
    && npm install \
    && npm run build


FROM golang:1.25-alpine3.23 AS go-builder

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG RELEASE_BUILD=1

ARG VERSION=1.13.0

RUN set -eux \
    && apk add --no-cache binutils-gold bash gcc g++ make git binutils elogind-dev \
    && addgroup -g 1001 gorelease \
    && adduser -D -u 1001 -G gorelease gorelease

USER 1001:1001

WORKDIR /go/src/github.com/grafana/alloy

RUN set -eux \
    && git clone -b v${VERSION} --single-branch --depth=1 https://github.com/grafana/alloy.git . \
    && sed -i 's#BuildUser=$(shell whoami)@$(shell hostname)#BuildUser=$(shell whoami)#' Makefile

COPY --from=ui-builder /ui/dist /go/src/github.com/grafana/alloy/internal/web/ui/dist

RUN GOOS="$TARGETOS" GOARCH="$TARGETARCH" GOARM=${TARGETVARIANT#v} \
    RELEASE_BUILD=${RELEASE_BUILD} VERSION=${VERSION} \
    GO_TAGS="netgo builtinassets promtail_journal_enabled" \
    make alloy

FROM alpine:3.23

ARG UID="473"
ARG USERNAME="alloy"

LABEL org.opencontainers.image.source="https://github.com/grafana/alloy"

RUN apk add --no-cache ca-certificates tzdata musl-utils

COPY --from=go-builder --chown=${UID}:${UID} /go/src/github.com/grafana/alloy/build/alloy /usr/local/bin/
COPY --from=go-builder --chown=${UID}:${UID} /go/src/github.com/grafana/alloy/example-config.alloy /etc/alloy/config.alloy
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