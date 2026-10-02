#!/usr/bin/env bash
# Build and push the UBI9 Perfana images:  ./build.sh registry.example.com/perfana [version]
# Tags: <repo>/perfana-<component>:<version>-ubi9
set -euo pipefail
REPO="${1:?usage: $0 <registry/namespace> [version]}"
VERSION="${2:-0.2.96.27}"
cd "$(dirname "$0")"
for c in api web worker grafana-sync report migration; do
  docker build --platform "${PLATFORM:-linux/amd64}" --build-arg PERFANA_VERSION="$VERSION" \
    --target "$c" -t "$REPO/perfana-$c:$VERSION-ubi9" .
  [[ -n "${NO_PUSH:-}" ]] || docker push "$REPO/perfana-$c:$VERSION-ubi9"
done
