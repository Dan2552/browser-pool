FROM mcr.microsoft.com/playwright:v1.51.0-noble

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      dbus-x11 \
      openbox \
      python3-dbus \
      python3-lz4 \
      python3-paramiko \
      python3-pyinotify \
      python3-xdg \
      xfonts-base \
      xterm \
    && curl -fsSL https://xpra.org/gpg.asc | gpg --dearmor -o /usr/share/keyrings/xpra.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/xpra.gpg] https://xpra.org/ noble main" > /etc/apt/sources.list.d/xpra.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      xpra=6.4.3-r0-1 \
      xpra-server=6.4.3-r0-1 \
      xpra-x11=6.4.3-r0-1 \
      xpra-html5=19-r1-1 \
    && rm -rf /var/lib/apt/lists/*

# Allow Xpra to be embedded in iframes (for the dashboard)
RUN printf '%s\n' \
  '# Allow framing from any origin for browser-pool dashboard' \
  'Content-Security-Policy: script-src '"'"'self'"'"' '"'"'unsafe-inline'"'"' ; font-src '"'"'self'"'"' ; object-src '"'"'none'"'"' ; child-src '"'"'self'"'"' ; worker-src '"'"'self'"'"' ; frame-ancestors * ; form-action '"'"'self'"'"' ; block-all-mixed-content;' \
  'Cross-Origin-Resource-Policy : cross-origin' \
  'Access-Control-Allow-Origin : *' \
  'Referrer-Policy: no-referrer' \
  > /etc/xpra/http-headers/10_content_security_policy.txt

WORKDIR /work

COPY start-xpra.sh /usr/local/bin/start-xpra
RUN chmod +x /usr/local/bin/start-xpra

CMD ["start-xpra"]
