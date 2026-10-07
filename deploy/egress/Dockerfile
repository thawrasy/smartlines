# Egress proxy (audit T3-02): Squid from Debian, with the configuration of this directory
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends squid ca-certificates \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /etc/squid/lists /var/run/squid /var/log/squid \
    && chown -R proxy:proxy /var/run/squid /var/log/squid
COPY squid.conf allowlist.txt /etc/squid/
COPY entrypoint.sh /entrypoint.sh
EXPOSE 3128
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
