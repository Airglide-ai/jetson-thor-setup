# Tang server (Network-Bound Disk Encryption) for Clevis clients.
# Uses the official Debian "tang" package; socat replaces systemd socket activation.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends tang socat \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s "$(dpkg -L tang tang-common 2>/dev/null | grep -m1 '/tangd$')" /usr/local/bin/tangd \
 && ln -s "$(dpkg -L tang tang-common 2>/dev/null | grep -m1 '/tangd-keygen$')" /usr/local/bin/tangd-keygen \
 && test -x /usr/local/bin/tangd && test -x /usr/local/bin/tangd-keygen

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME /var/db/tang
EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=5s --retries=3 \
  CMD ["sh", "-c", "printf 'GET /adv HTTP/1.0\\r\\n\\r\\n' | socat - TCP:127.0.0.1:8080 | grep -q payload"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
