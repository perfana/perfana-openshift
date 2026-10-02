# syntax=docker/dockerfile:1
# ==================================================================================================
# Perfana on Red Hat UBI9
# --------------------------------------------------------------------------------------------------
# Repackages the published Perfana release onto ubi9/nodejs-20-minimal; nothing is rebuilt.
# The upstream images install dependencies with --ignore-scripts and run the same /app on
# Debian (distroless) as on Alpine, so /app is portable; the only native addons
# (msgpackr-extract) ship glibc prebuilds, which UBI9 satisfies.
#
# /app is group-0 owned and group-writable (OpenShift convention), so every image runs
# under restricted-v2 with a random uid — no nonroot-v2 SCC needed for perfana-web.
#
#   ./build.sh <registry>/perfana            (see README.md)
# ==================================================================================================
ARG PERFANA_VERSION=0.2.96.27
ARG UBI_NODE=registry.access.redhat.com/ubi9/nodejs-20-minimal:latest

FROM perfana/perfana-api:${PERFANA_VERSION} AS upstream-app
FROM perfana/perfana-migration:${PERFANA_VERSION} AS upstream-migration

# chmod in a throwaway stage so the runtime layer is written once.
FROM ${UBI_NODE} AS prep
USER 0
COPY --from=upstream-app /app /app
COPY --from=upstream-migration /app /migration
RUN chgrp -R 0 /app /migration && chmod -R g=u /app /migration

FROM ${UBI_NODE} AS base
COPY --from=prep --chown=1001:0 /app /app
WORKDIR /app
ENV NODE_ENV=production HOME=/tmp
USER 1001

FROM base AS api
ENV PORT=3001
EXPOSE 3001
CMD ["node", "apps/api/dist/main.js"]

FROM base AS web
ENV PORT=3000 HOSTNAME=0.0.0.0 NEXT_TELEMETRY_DISABLED=1
EXPOSE 3000
WORKDIR /app/apps/web
CMD ["node", "scripts/start-server.js"]

FROM base AS worker
CMD ["node", "apps/worker/dist/worker.js"]

FROM base AS grafana-sync
ENV PORT=3002
CMD ["node", "apps/grafana-sync/dist/src/main.js"]

# EPEL chromium needs pipewire/double-conversion, which are in RHEL but not UBI repos, so
# use Google's Chrome for Testing headless shell (a standalone build). Pin with CHROME_VERSION:
# https://googlechromelabs.github.io/chrome-for-testing/
FROM base AS report
ARG CHROME_VERSION=154.0.8037.92
USER 0
RUN microdnf install -y --setopt=install_weak_deps=0 unzip \
        nss nspr atk at-spi2-atk at-spi2-core dbus-libs expat alsa-lib mesa-libgbm libxkbcommon \
        libX11 libxcb libXcomposite libXdamage libXext libXfixes libXrandr \
        fontconfig dejavu-sans-fonts \
    && curl -fsSLo /tmp/chrome.zip "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-headless-shell-linux64.zip" \
    && unzip -q /tmp/chrome.zip -d /opt && rm /tmp/chrome.zip \
    && ln -s /opt/chrome-headless-shell-linux64/chrome-headless-shell /usr/bin/chromium-browser \
    && microdnf clean all
USER 1001
ENV PORT=3003 PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
EXPOSE 3003
CMD ["node", "apps/perfana-report/dist/src/main.js"]

FROM ${UBI_NODE} AS migration
COPY --from=prep --chown=1001:0 /migration /app
WORKDIR /app
ENV NODE_ENV=production HOME=/tmp
USER 1001
CMD ["node", "run-migrations.js"]
