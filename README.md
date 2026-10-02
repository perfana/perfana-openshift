# Perfana on OpenShift

Kustomize manifests to deploy Perfana on OpenShift 4.11+. They mirror the docker compose
deployment in `perfana-demo` branch `poc-windows-wsl`: same images and tags, same tuning,
same Keycloak realm, Grafana provisioning and bootstrap steps.

| Workload | Image | Exposed as |
|---|---|---|
| `postgres` (StatefulSet, 200Gi) | timescale/timescaledb-ha:pg15 | Service only |
| `valkey` (StatefulSet, 5Gi) | valkey/valkey:8-alpine | Service only |
| `keycloak` | quay.io/keycloak/keycloak:24.0 | Route `KEYCLOAK_HOST` |
| `perfana-api` (+ `migration` initContainer) | perfana/perfana-api, perfana/perfana-migration | Route `API_HOST` |
| `perfana-web` | perfana/perfana-web | Route `PERFANA_HOST` |
| `perfana-worker`, `perfana-grafana-sync`, `perfana-report` | perfana/* | — |
| `grafana` | grafana/grafana:12.4 | Route `GRAFANA_HOST` |

All Routes use edge TLS with the cluster's router certificate.

## Install

```bash
oc new-project perfana            # namespace is set in kustomization.yaml
vi params.env                     # Route hostnames, proxy
cp secrets.env.example secrets.env && vi secrets.env   # strong values, see comments
oc apply --server-side -k .       # server-side: the dashboards ConfigMap exceeds the client-side annotation limit
oc get pods -w                    # wait until all are Ready (first Keycloak start takes a few minutes)
./bootstrap.sh                    # once; idempotent. CURL_OPTS=-k for a self-signed router cert
```

`bootstrap.sh` runs locally and needs `oc`, `curl` and `jq`. It sets the Keycloak client secrets,
redirect URIs and CSP for your hosts, sets the admin password, and creates the organization.
It also registers Grafana and creates a Perfana API key, which it prints once.

## Requirements

- **cluster-admin, once**, to create `manifests/rbac.yaml`. It grants the `nonroot-v2` SCC to the
  `nonroot` service account, and two workloads need it to run as the UID built into their image:
  - postgres (uid 1000): initdb and pgdata expect that user.
  - perfana-web (uid 65532): at startup it rewrites `__env.js` and the CSP in `routes-manifest.json`.
    Under a random UID that write fails without an error, and the embedded Grafana panels stop loading.

  Everything else runs under the default `restricted-v2` SCC.
- Pulls from Docker Hub (`perfana/*`, `timescale`, `valkey`, `grafana`) and quay.io. If the cluster
  pulls through a mirror, override the images in `kustomization.yaml` (`images:`). If it needs a
  pull secret, link it with `oc secrets link default <secret> --for=pull`, and also for `nonroot`.
- Grafana installs two plugins at startup (`GF_PLUGINS_PREINSTALL_SYNC`), so it needs outbound
  access to grafana.com.
- A default StorageClass with RWO volumes, preferably SSD. Postgres is tuned for SSD
  (`random_page_cost=1.1`).
- Postgres is sized for a ~20 GB node (`shared_buffers=4GB`, memory limit 12Gi). On a smaller
  node, lower the `-c` args in `manifests/postgres.yaml` together with the limits.

## Upgrade

Bump `newTag` under `images:` in `kustomization.yaml`, then run `oc apply --server-side -k .`.
The new perfana-api pod runs the migrations in its initContainer before it starts.

## Differences from poc-windows-wsl

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
(all three databases: perfana, keycloak, grafana). Alternatively, take volume snapshots of `data-postgres-0`.
