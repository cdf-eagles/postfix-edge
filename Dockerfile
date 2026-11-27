FROM docker.io/library/alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# hadolint ignore=DL3018
RUN apk upgrade --no-cache \
    && apk add --no-cache postfix \
    && apk info -e postfix \
    && postconf -d mail_version \
    && mkdir -p /etc/postfix-edge/tls /etc/postfix-edge/main.cf.d \
    && cp /etc/postfix/main.cf /etc/postfix-edge/main.cf.dist

COPY rootfs/ /

RUN chmod 0755 /usr/local/bin/postfix-edge-entrypoint /usr/local/bin/postfix-edge-healthcheck \
    && test -x /usr/local/bin/postfix-edge-entrypoint \
    && test -x /usr/local/bin/postfix-edge-healthcheck \
    && test -r /etc/postfix-edge/main.cf.defaults

EXPOSE 25
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD ["/usr/local/bin/postfix-edge-healthcheck"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/postfix-edge-entrypoint"]

LABEL org.opencontainers.image.title="postfix-edge" \
      org.opencontainers.image.description="Postfix as an inbound edge MTA that relays mail for its domains to an LMTP backend"
