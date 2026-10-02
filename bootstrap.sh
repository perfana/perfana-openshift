#!/usr/bin/env bash
# ==================================================================================================
# Perfana on OpenShift - first-run bootstrap (port of poc-windows-wsl bootstrap.sh)
# --------------------------------------------------------------------------------------------------
# Run ONCE after `oc apply -k .` and all pods are Ready. Idempotent.
#   1. Align Keycloak client secrets with secrets.env
#   2. Point Keycloak redirect URIs / web origins / CSP at the Route hosts; disable
#      self-registration, require HTTPS for external clients
#   3. Set the Perfana admin password and enable password-grant login
#   4. Create the Perfana organization and make the admin an org-admin
#   5. Re-apply provisioning (benchmarks, dashboards) under that organization
#   6. Register the existing Grafana in Perfana
#   7. Create a Perfana API key for load-test result submission
#
# Requires: oc (logged in), curl, jq. Talks to Perfana/Keycloak over the Routes.
# Self-signed router certificate?  CURL_OPTS=-k ./bootstrap.sh
# ==================================================================================================
set -uo pipefail
cd "$(dirname "$0")"

[[ -f secrets.env ]] || { echo "ERROR: secrets.env not found." >&2; exit 1; }
set -a; . ./params.env; . ./secrets.env; set +a
command -v jq >/dev/null || { echo "ERROR: jq is required." >&2; exit 1; }

NS="${NS:-perfana}"
OC=(oc -n "$NS")
REALM="perfana-prod"
ORG_NAME="${PERFANA_ORG_NAME:-Perfana}"
PERFANA_USER="${PERFANA_ADMIN_USER:-admin@perfana.io}"
PERFANA_PW="${PERFANA_ADMIN_PASSWORD:?PERFANA_ADMIN_PASSWORD must be set}"
WEB_URL="https://$PERFANA_HOST"
API_URL="https://$API_HOST"
KC_URL="https://$KEYCLOAK_HOST"
CURL=(curl -s ${CURL_OPTS:-})
# kcadm keeps its session in $HOME; the random OpenShift uid has no writable home.
KC=("${OC[@]}" exec deploy/keycloak -- env HOME=/tmp /opt/keycloak/bin/kcadm.sh)
PSQL=("${OC[@]}" exec -i perfana-db-1 -c postgres -- psql -d perfana -v ON_ERROR_STOP=1)

wait_for() { # url label tries
  echo "       Waiting for $2..."
  for _ in $(seq 1 "${3:-60}"); do
    "${CURL[@]}" -f "$1" >/dev/null 2>&1 && { echo "       $2 ready."; return 0; }
    sleep 2
  done
  echo "       WARNING: $2 not ready in time."; return 1
}

client_uuid() { "${KC[@]}" get clients -r "$REALM" -q "clientId=$1" --fields id --format csv 2>/dev/null | tr -d '"\r' | head -1; }

echo "==> Configuring Keycloak (realm: $REALM)"
"${KC[@]}" config credentials --server http://localhost:8080 --realm master \
  --user "${KEYCLOAK_ADMIN:-admin}" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1 \
  || { echo "ERROR: kcadm login failed. Is Keycloak ready?" >&2; exit 1; }

# 1. Client secrets
for pair in "perfana-api:${KEYCLOAK_CLIENT_SECRET:-}" "perfana-admin:${KEYCLOAK_ADMIN_CLIENT_SECRET:-}"; do
  cid="${pair%%:*}"; secret="${pair#*:}"
  [[ -z "$secret" ]] && continue
  uuid="$(client_uuid "$cid")"
  [[ -n "$uuid" ]] && { "${KC[@]}" update "clients/$uuid" -r "$REALM" -s "secret=$secret" >/dev/null 2>&1 \
    && echo "    - $cid secret set" || echo "    - WARNING: could not set $cid secret"; }
done

# 2. Redirect URIs / web origins / realm CSP
web_uuid="$(client_uuid perfana-web)"
[[ -n "$web_uuid" ]] && "${KC[@]}" update "clients/$web_uuid" -r "$REALM" \
  -s "redirectUris=[\"$WEB_URL/*\"]" -s "webOrigins=[\"$WEB_URL\"]" -s directAccessGrantsEnabled=true >/dev/null 2>&1 \
  && echo "    - perfana-web client updated"
csp="frame-src 'self' $GRAFANA_URL $WEB_URL; frame-ancestors 'self' $GRAFANA_URL $WEB_URL; object-src 'none';"
# No self-registration; HTTPS required except from private addresses (in-cluster calls stay HTTP).
"${KC[@]}" update "realms/$REALM" -s "browserSecurityHeaders.contentSecurityPolicy=$csp" \
  -s registrationAllowed=false -s sslRequired=external >/dev/null 2>&1 \
  && echo "    - realm CSP, registration off, sslRequired=external"

# 3. Admin password; disable OTP in the direct-grant flow so password-grant works headless
uid="$("${KC[@]}" get users -r "$REALM" -q "username=$PERFANA_USER" --fields id --format csv 2>/dev/null | tr -d '"\r' | head -1)"
if [[ -n "$uid" ]]; then
  "${KC[@]}" set-password -r "$REALM" --username "$PERFANA_USER" --new-password "$PERFANA_PW" >/dev/null 2>&1 \
    && echo "    - password set for $PERFANA_USER"
else
  echo "    - WARNING: user $PERFANA_USER not found in realm"
fi
"${KC[@]}" get "authentication/flows/direct%20grant/executions" -r "$REALM" 2>/dev/null \
  | jq -r '.[] | select(.displayName | test("OTP";"i")) | .id' 2>/dev/null \
  | while read -r exid; do
      [[ -n "$exid" ]] && "${KC[@]}" update "authentication/flows/direct%20grant/executions" -r "$REALM" \
        -b "{\"id\":\"$exid\",\"requirement\":\"DISABLED\"}" >/dev/null 2>&1 || true
    done

echo "==> Waiting for services"
wait_for "$API_URL/api/health" "Perfana API" 60

get_token() {
  "${CURL[@]}" "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=perfana-web \
    --data-urlencode "username=$PERFANA_USER" --data-urlencode "password=$PERFANA_PW" | jq -r '.access_token // empty'
}
api() { "${CURL[@]}" -f -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }

echo "==> Configuring Perfana"
TOKEN="$(get_token)"
[[ -z "$TOKEN" ]] && { echo "ERROR: no token from Keycloak for $PERFANA_USER." >&2; exit 1; }

# 4. Organization + membership
ORG_ID="$(api -X POST "$API_URL/api/organizations" -d "{\"name\":\"$ORG_NAME\",\"description\":\"$ORG_NAME\"}" | jq -r '.id // empty')"
[[ -z "$ORG_ID" ]] && ORG_ID="$(api "$API_URL/api/organizations" | jq -r ".[] | select(.name==\"$ORG_NAME\") | .id" | head -1)"
[[ -z "$ORG_ID" ]] && { echo "ERROR: could not create/find organization '$ORG_NAME'." >&2; exit 1; }
echo "    - organization '$ORG_NAME': $ORG_ID"

sub="$(echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | { read -r p; printf '%s%s' "$p" "$(printf '=%.0s' $(seq 1 $(( (4 - ${#p} % 4) % 4 ))))"; } | base64 -d 2>/dev/null | jq -r '.sub // empty')"
if [[ -n "$sub" && "$(api "$API_URL/api/organizations/$ORG_ID/members" | jq "[.[] | select(.user_id==\"$sub\")] | length")" == "0" ]]; then
  api -X POST "$API_URL/api/organizations/$ORG_ID/members" -d "{\"userId\":\"$sub\",\"roles\":[\"org-admin\"]}" >/dev/null \
    && echo "    - $PERFANA_USER added as org-admin"
fi

# 5. Provisioning under the real org id. The YAMLs are a ConfigMap; rewriting them and
#    re-applying rolls perfana-api (new ConfigMap hash), the DB rows are fixed in place.
for f in config/perfana/provisioning/{profiles,profile_grafana_dashboards,profile_benchmarks,template_ds_compare_configs}.yaml; do
  sed -i.bak "s|^organizationId:.*|organizationId: ${ORG_ID}|" "$f" && rm -f "$f.bak"
done
"${PSQL[@]}" -c "
  UPDATE profiles                                SET organization_id='${ORG_ID}'::uuid WHERE organization_id<>'${ORG_ID}'::uuid;
  UPDATE profile_benchmarks                      SET organization_id='${ORG_ID}'::uuid WHERE organization_id<>'${ORG_ID}'::uuid;
  UPDATE profile_grafana_dashboards              SET organization_id='${ORG_ID}'::uuid WHERE organization_id<>'${ORG_ID}'::uuid;
  UPDATE provisioned_template_ds_compare_configs SET organization_id='${ORG_ID}'::uuid WHERE organization_id<>'${ORG_ID}'::uuid;
" >/dev/null && echo "    - provisioned rows reattached"
oc apply -n "$NS" -k . >/dev/null   # new ConfigMap hash rolls perfana-api
"${OC[@]}" rollout status deploy/perfana-api --timeout=5m
TOKEN="$(get_token)"   # refresh: token now carries org membership

# 6. Register the existing Grafana (GRAFANA_URL + GRAFANA_API_TOKEN) in Perfana
existing="$(api "$API_URL/api/grafana-instances" | jq -r '.[0].id // empty')"
if [[ -z "${GRAFANA_API_TOKEN:-}" ]]; then
  echo "    - GRAFANA_API_TOKEN empty: register Grafana from the Perfana UI"
elif [[ -z "$existing" ]]; then
  api -X POST "$API_URL/api/grafana-instances" -d "{\"label\":\"Grafana\",\"clientUrl\":\"$GRAFANA_URL\",
    \"serverUrl\":\"$GRAFANA_URL\",\"orgId\":\"1\",\"apiKey\":\"$GRAFANA_API_TOKEN\",\"organizationId\":\"$ORG_ID\"}" >/dev/null \
    && echo "    - Grafana registered in Perfana"
else
  api -X PATCH "$API_URL/api/grafana-instances/$existing" -d "{\"apiKey\":\"$GRAFANA_API_TOKEN\"}" >/dev/null \
    && echo "    - Grafana instance key updated"
fi

# 7. API key for load generators
API_KEY="$(api "$API_URL/api/api-keys" -d '{"ttl":"1y","description":"default"}' | jq -r '.token // empty')"

cat <<EOF

==================================================================
 Bootstrap complete.
   Perfana UI : $WEB_URL   (login: $PERFANA_USER)
   Keycloak   : $KC_URL
${API_KEY:+
   Perfana API key (store securely - shown once):
     $API_KEY}
==================================================================
EOF
