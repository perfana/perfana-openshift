# Perfana UBI9 images

Builds the Perfana components on Red Hat UBI9 (`registry.access.redhat.com/ubi9/nodejs-20-minimal`).
They are repackaged from the published `perfana/*` release images, so no Perfana source is needed
and the application code is identical to upstream.

```bash
./build.sh registry.example.com/perfana            # builds + pushes all six, linux/amd64
./build.sh registry.example.com/perfana 0.2.96.28  # another release
NO_PUSH=1 ./build.sh local/perfana                 # build only
```

The build produces `<repo>/perfana-{api,web,worker,grafana-sync,report,migration}:<version>-ubi9`.

To deploy them, point the `images:` entries in `../kustomization.yaml` at your registry:

```yaml
  - name: perfana/perfana-api
    newName: registry.example.com/perfana/perfana-api
    newTag: 0.2.96.27-ubi9
```

Notes
- `/app` belongs to group 0 and is group-writable, so every image runs under the default
  `restricted-v2` SCC with a random UID. perfana-web no longer needs the `nonroot-v2` SCC; only
  postgres still does.
- **perfana-report**: EPEL's Chromium needs libraries (pipewire, double-conversion) that are only in
  the subscription RHEL repos, so the report image uses Google's Chrome for Testing
  `chrome-headless-shell` instead. All of its runtime libraries come from the UBI repos. The version
  is pinned with `--build-arg CHROME_VERSION=...`.
  It is not Red Hat software: if your policy requires only RPM-packaged components, build on an
  entitled RHEL host and switch the report stage to EPEL `chromium-headless`.
- Builds for `linux/amd64` by default (`PLATFORM=linux/arm64 ./build.sh ...` to change).
