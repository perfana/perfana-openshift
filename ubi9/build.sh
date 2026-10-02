#!/usr/bin/env bash
# Build and push the UBI9 images:  ./build.sh registry.example.com/perfana [version]
# Tags: <repo>/perfana-<component>:<version>-ubi9 and <repo>/cnpg-timescaledb:18-ts2.30.2
set -euo pipefail
REPO="${1:?usage: $0 <registry/namespace> [version]}"
VERSION="${2:-0.2.96.27}"
PLATFORM="${PLATFORM:-linux/amd64}"
cd "$(dirname "$0")"
push() { [[ -n "${NO_PUSH:-}" ]] || docker push "$1"; }

for c in api web worker grafana-sync report migration; do
  docker build --platform "$PLATFORM" --build-arg PERFANA_VERSION="$VERSION" \
    --target "$c" -t "$REPO/perfana-$c:$VERSION-ubi9" .
  push "$REPO/perfana-$c:$VERSION-ubi9"
done

# CNPG operand. openshift-perms = PG + TimescaleDB + Toolkit, no barman (use the Barman Cloud
# Plugin for backups); --target system adds in-tree barman-cloud.
docker build --platform "$PLATFORM" -f Containerfile.cnpg --build-arg PG_MAJOR=18 --build-arg TS_VERSION=2.30.2 \
  --target "${CNPG_TARGET:-openshift-perms}" -t "$REPO/cnpg-timescaledb:18-ts2.30.2" .
push "$REPO/cnpg-timescaledb:18-ts2.30.2"
