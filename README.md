# Perfana on OpenShift

Kustomize manifests to deploy Perfana on OpenShift 4.11+. They mirror the docker compose
deployment in `perfana-demo` branch `poc-windows-wsl`: same Perfana release (as UBI9 images, see
`ubi9/`), same tuning,
same Keycloak realm and bootstrap steps. Grafana is not deployed: Perfana uses an existing
Grafana (`GRAFANA_URL` in `params.env`).

| Workload | Image | Exposed as |
|---|---|---|
| `postgres` (StatefulSet, 200Gi) | timescale/timescaledb-ha:pg18.6-ts2.30.2 | Service only |
| `valkey` (StatefulSet, 5Gi) | valkey/valkey:8-alpine | Service only |
| `keycloak` | quay.io/keycloak/keycloak:24.0 | Route `KEYCLOAK_HOST` |
| `perfana-api` (+ `migration` initContainer) | perfana-api, perfana-migration `:0.2.96.27-ubi9` | Route `API_HOST` |
| `perfana-web` | perfana-web `:0.2.96.27-ubi9` | Route `PERFANA_HOST` |
| `perfana-worker`, `perfana-grafana-sync`, `perfana-report` | perfana-* `:0.2.96.27-ubi9` | — |

All Routes use edge TLS with the cluster's router certificate.

## Install

```bash
oc new-project perfana            # namespace is set in kustomization.yaml

# Perfana UBI9 images -> the internal registry, perfana namespace (needs docker + the registry's
# external route: oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
#   -p '{"spec":{"defaultRoute":true}}'   — cluster-admin, once)
oc registry login
ubi9/build.sh "$(oc registry info --public)/perfana"
vi params.env                     # Route hostnames, GRAFANA_URL, proxy
cp secrets.env.example secrets.env && vi secrets.env   # strong values, see comments
oc apply -k .
oc get pods -w                    # wait until all are Ready (first Keycloak start takes a few minutes)
./bootstrap.sh                    # once; idempotent. CURL_OPTS=-k for a self-signed router cert
```

`bootstrap.sh` runs locally and needs `oc`, `curl` and `jq`. It sets the Keycloak client secrets,
redirect URIs and CSP for your hosts, sets the admin password, and creates the organization.
It registers your Grafana if `GRAFANA_API_TOKEN` is set (a service-account token with the Admin
role), and creates a Perfana API key, which it prints once.

## Requirements

- **cluster-admin, once**, to create `manifests/rbac.yaml`. It grants the `nonroot-v2` SCC to the
  `nonroot` service account, which only postgres uses: `initdb` refuses to run under a random UID,
  so it runs as the image's uid 1000. Everything else runs under the default `restricted-v2` SCC.
- The Perfana images come from the OpenShift internal registry (built by `ubi9/build.sh`, see
  Install). To use another registry, change `newName` under `images:` in `kustomization.yaml`
  and link its pull secret: `oc secrets link default <secret> --for=pull`.
- postgres, valkey and keycloak are pulled from Docker Hub and quay.io. Behind a mirror, add them
  to `images:` as well.
- An existing Grafana that both the browser and the perfana-worker / perfana-grafana-sync pods can
  reach. Its CSP and X-Frame settings must allow embedding (`allow_embedding = true`) from `PERFANA_HOST`.
  The branch also installed the `marcusolsson-json-datasource` and `grafana-pyroscope-app` plugins;
  add them there if you use them.
- A default StorageClass with RWO volumes, preferably SSD. Postgres is tuned for SSD
  (`random_page_cost=1.1`).
- Postgres is sized for a ~20 GB node (`shared_buffers=4GB`, memory limit 12Gi). On a smaller
  node, lower the `-c` args in `manifests/postgres.yaml` together with the limits.

## Upgrade

Build the new release (`ubi9/build.sh "$(oc registry info --public)/perfana" <version>`), bump
`newTag` under `images:` in `kustomization.yaml` to `<version>-ubi9`, then run `oc apply -k .`.
The new perfana-api pod runs the migrations in its initContainer before it starts.

## Differences from poc-windows-wsl

- Omitted: Grafana, its Keycloak SSO, its datasource/dashboard provisioning and its alert webhook
  to Perfana. Configure those on your own Grafana if you need them; the files are in git history.
- Omitted (they depend on Docker): docker-socket-proxy, the docker-monitor/valkey-monitor samplers
  and the "Docker resources" dashboard. `LOG_VIEWER_ENABLED=false` for the same reason.
- Omitted: libredb (SQL IDE) and pgbouncer. Postgres is not exposed outside the cluster. If load
  generators outside the cluster write results directly to the database, add a LoadBalancer
  Service or `oc port-forward`.
- Keycloak runs `start` (production mode) behind the edge Route instead of `start-dev`.
- The API runs on its own host, because perfana-web serves its own `/api/config` and the two
  can't share one host under `/api`.
- `perfana-migration` runs as an initContainer of perfana-api instead of a one-shot service.
- `SUT_TRANSFER_ENABLED=true`, the same as the branch. That export includes connection rows, so
  set it to `false` in perfana-api and perfana-web if admins should not be able to export them.

## Backups

`oc exec postgres-0 -- pg_dumpall -U perfana | gzip > perfana-$(date +%F).sql.gz`
(both databases: perfana, keycloak). Alternatively, take volume snapshots of `data-postgres-0`.
