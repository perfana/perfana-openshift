# Perfana UBI9 images

Builds the Perfana components on Red Hat UBI9 (`registry.access.redhat.com/ubi9/nodejs-20-minimal`).
They are repackaged from the published `perfana/*` release images, so no Perfana source is needed
and the application code is identical to upstream.

```bash
./build.sh registry.example.com/perfana            # builds + pushes all six, linux/amd64
./build.sh registry.example.com/perfana 0.2.96.28  # another release
NO_PUSH=1 ./build.sh local/perfana                 # build only
```

The build produces `<repo>/perfana-{api,web,worker,grafana-sync,report,migration}:<version>-ubi9`,
plus the database image `<repo>/cnpg-timescaledb:18-ts2.30.2` from `Containerfile.cnpg`. That image is the
CloudNativePG operand: UBI9, PostgreSQL 18.6 (PGDG), TimescaleDB 2.30.2, Toolkit, uuid-ossp, uid 26.
By default it builds the `openshift-perms` target without barman; `CNPG_TARGET=system` adds barman-cloud.

`../kustomization.yaml` deploys them from the OpenShift internal registry
(`image-registry.openshift-image-registry.svc:5000/perfana/...`). Push there with
`./build.sh "$(oc registry info --public)/perfana"` after `oc registry login`, or change `newName`
in `../kustomization.yaml` to use another registry.

Notes
- `/app` belongs to group 0 and is group-writable, so every image runs under the default
  `restricted-v2` SCC with a random UID.
- **perfana-report**: EPEL's Chromium needs libraries (pipewire, double-conversion) that are only in
  the subscription RHEL repos, so the report image uses Google's Chrome for Testing
  `chrome-headless-shell` instead. All of its runtime libraries come from the UBI repos. The version
  is pinned with `--build-arg CHROME_VERSION=...`.
  It is not Red Hat software: if your policy requires only RPM-packaged components, build on an
  entitled RHEL host and switch the report stage to EPEL `chromium-headless`.
- Builds for `linux/amd64` by default (`PLATFORM=linux/arm64 ./build.sh ...` to change).
