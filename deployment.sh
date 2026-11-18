
#!/usr/bin/env bash

set -Eeuo pipefail

# --------------------------------------------------
# CONFIGURATION
# --------------------------------------------------

NAMESPACE="${NAMESPACE:-pinghelm}"
RELEASE="${RELEASE:-demo}"

PING_HOME="${PING_IDENTITY_DEVOPS_HOME:-$HOME/ping-devops}"
REPO_URL="https://github.com/pingidentity/pingidentity-devops-getting-started.git"

CHART_REPO="https://helm.pingidentity.com/"
CHART_NAME="pingidentity/ping-devops"

TIMEOUT="${TIMEOUT:-25m}"

# --------------------------------------------------
# VALIDATE PREREQUISITES
# --------------------------------------------------

for cmd in oc helm git; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: $cmd is not installed."
        exit 1
    }
done

oc whoami >/dev/null 2>&1 || {
    echo "ERROR: Login to OpenShift first using oc login."
    exit 1
}

: "${PING_IDENTITY_DEVOPS_USER:?Set PING_IDENTITY_DEVOPS_USER}"
: "${PING_IDENTITY_DEVOPS_KEY:?Set PING_IDENTITY_DEVOPS_KEY}"

export PING_IDENTITY_ACCEPT_EULA="${PING_IDENTITY_ACCEPT_EULA:-YES}"

echo "======================================"
echo " Ping Identity OpenShift Deployment"
echo "======================================"

echo "OpenShift user: $(oc whoami)"
echo "Namespace: $NAMESPACE"
echo "Release: $RELEASE"

# --------------------------------------------------
# CREATE PROJECT
# --------------------------------------------------

if ! oc get project "$NAMESPACE" >/dev/null 2>&1; then
    oc new-project "$NAMESPACE"
else
    echo "Project $NAMESPACE already exists."
fi

oc project "$NAMESPACE"

# --------------------------------------------------
# CLONE PING DEVOPS REPOSITORY
# --------------------------------------------------

mkdir -p "$PING_HOME"

if [[ ! -d "$PING_HOME/pingidentity-devops-getting-started/.git" ]]; then
    git clone "$REPO_URL" \
      "$PING_HOME/pingidentity-devops-getting-started"
else
    git -C "$PING_HOME/pingidentity-devops-getting-started" pull
fi

HELM_DIR="$PING_HOME/pingidentity-devops-getting-started/30-helm"

cd "$HELM_DIR"

[[ -f everything.yaml ]] || {
    echo "ERROR: everything.yaml not found."
    exit 1
}

# --------------------------------------------------
# CREATE PING DEVOPS SECRET
# --------------------------------------------------

oc create secret generic devops-secret \
  --from-literal=PING_IDENTITY_DEVOPS_USER="$PING_IDENTITY_DEVOPS_USER" \
  --from-literal=PING_IDENTITY_DEVOPS_KEY="$PING_IDENTITY_DEVOPS_KEY" \
  --from-literal=PING_IDENTITY_ACCEPT_EULA="$PING_IDENTITY_ACCEPT_EULA" \
  --dry-run=client -o yaml | oc apply -f -

# --------------------------------------------------
# CREATE OPENSHIFT VALUES FILE
# --------------------------------------------------

cat > openshift-values.yaml <<'EOF'
global:
  workload:
    securityContext:
      fsGroup: null
      runAsUser: null

  externalImage:
    pingtoolkit:
      securityContext:
        runAsUser: null

  ingress:
    enabled: false
EOF

cat > custom-deployment.yaml <<'EOF'
global:
  envs:
    PING_IDENTITY_ACCEPT_EULA: "YES"
  workload:
    securityContext:
      fsGroup: null
      runAsUser: null

pingdirectory:
  enabled: true
  envs:
    SERVER_PROFILE_URL: https://www.github.com/pingidentity/pingidentity-server-profiles.git
    SERVER_PROFILE_PATH: baseline/pingdirectory


#############################################################
# pingfederate-admin values
#############################################################
pingfederate-admin:
  enabled: true
  envs:
    SERVER_PROFILE_URL: https://github.com/pingidentity/pingidentity-server-profiles.git
    SERVER_PROFILE_PATH: baseline/pingfederate
    #PF_RUN_PF_ADMIN_BASEURL: "https://pingfederate-admin-route-nakerikantiramu45-dev.apps.rm3.7wse.p1.openshiftapps.com"
    #PF_RUN_PF_ADMIN_HOSTNAME: "pingfederate-admin-route-nakerikantiramu45-dev.apps.rm3.7wse.p1.openshiftapps.com"

  image:
    repositoryFqn: docker.io/pingidentity/pingfederate
    tag: "2610"
    pullPolicy: IfNotPresent
#############################################################
# pingfederate-engine values
#############################################################
pingfederate-engine:
  enabled: true
  envs:
    SERVER_PROFILE_URL: https://github.com/pingidentity/pingidentity-server-profiles.git
    SERVER_PROFILE_PATH: baseline/pingfederate
  image:
    repositoryFqn: docker.io/pingidentity/pingfederate
    tag: "2610"
    pullPolicy: IfNotPresent
EOF
# --------------------------------------------------
# CONFIGURE HELM
# --------------------------------------------------

helm repo add pingidentity "$CHART_REPO" --force-update
helm repo update pingidentity

# --------------------------------------------------
# DEPLOY PING IDENTITY STACK
# --------------------------------------------------

echo "Deploying Ping Identity products..."

helm upgrade --install "$RELEASE" "$CHART_NAME" \
  --namespace "$NAMESPACE" \
  -f custom-deployment.yaml \
  -f openshift-values.yaml \
  --wait \
  --timeout "$TIMEOUT"

# --------------------------------------------------
# WAIT FOR APPLICATIONS
# --------------------------------------------------

echo "Waiting for application pods..."

oc wait pods \
  --all \
  --for=condition=Ready \
  --timeout="$TIMEOUT" \
  -n "$NAMESPACE" || {
    echo "WARNING: Some pods are not ready yet."
    oc get pods -n "$NAMESPACE"
}

# --------------------------------------------------
# CREATE OPENSHIFT PASSTHROUGH ROUTES
# --------------------------------------------------

create_route() {

    local service="$1"
    local route="$2"
    local service_port="$3"

    if ! oc get svc "$service" -n "$NAMESPACE" \
        >/dev/null 2>&1; then
        echo "Skipping $service (service not found)."
        return
    fi

    local port_name

    port_name=$(oc get svc "$service" -n "$NAMESPACE" \
      -o jsonpath="{.spec.ports[?(@.port==${service_port})].name}")

    if [[ -z "$port_name" ]]; then
        echo "Skipping $service: port $service_port not found."
        return
    fi

    echo "Creating passthrough route: $route"

    oc create route passthrough "$route" \
      --service="$service" \
      --port="$port_name" \
      -n "$NAMESPACE" \
      --dry-run=client -o yaml | oc apply -f -
}

# PingFederate
create_route \
  "$RELEASE-pingfederate-admin" \
  "$RELEASE-pf-admin" 9999

create_route \
  "$RELEASE-pingfederate-engine" \
  "$RELEASE-pf-engine" 9031

# PingAccess
#create_route \
#  "$RELEASE-pingaccess-admin" \
#  "$RELEASE-pa-admin" 9000

#create_route \
#  "$RELEASE-pingaccess-engine" \
#  "$RELEASE-pa-engine" 3000

# PingDataConsole
#create_route \
#  "$RELEASE-pingdataconsole" \
#  "$RELEASE-pdconsole" 8443

# PingAuthorize (if enabled)
#create_route \
#  "$RELEASE-pingauthorize" \
#  "$RELEASE-pingauthorize" 443

# --------------------------------------------------
# DISPLAY DEPLOYMENT INFORMATION
# --------------------------------------------------

echo
echo "======================================"
echo " DEPLOYMENT STATUS"
echo "======================================"

oc get pods -n "$NAMESPACE"

echo
echo "======================================"
echo " OPENSHIFT ROUTES"
echo "======================================"

oc get routes -n "$NAMESPACE"

echo
echo "======================================"
echo " SERVICES"
echo "======================================"

oc get svc -n "$NAMESPACE"

echo
echo "Deployment script completed."




# --------------------------------------------------
# UPDATE PINGFEDERATE ENGINE ADMIN & ENGINE URLS
# --------------------------------------------------

echo "Updating PingFederate Engine URLs..."

PF_ADMIN_HOST=$(oc get route "${RELEASE}-pf-admin" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}')

PF_ENGINE_HOST=$(oc get route "${RELEASE}-pf-engine" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}')

if [[ -z "$PF_ADMIN_HOST" || -z "$PF_ENGINE_HOST" ]]; then
    echo "ERROR: PingFederate Admin or Engine Route not found."
    exit 1
fi

PF_ADMIN_BASEURL="https://${PF_ADMIN_HOST}"
PF_ENGINE_BASEURL="https://${PF_ENGINE_HOST}"

echo "=================================================="
echo "PingFederate Admin"
echo "=================================================="
PF_ADMIN_DEPLOYMENT="${RELEASE}-pingfederate-admin"

# Update environment variables
oc set env deployment/"${PF_ADMIN_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  PF_RUN_PF_ADMIN_BASEURL="${PF_ADMIN_BASEURL}" \
  PF_RUN_PF_ADMIN_HOSTNAME="${PF_ADMIN_HOST}" \
  PF_RUN_PF_ENGINE_BASEURL="${PF_ENGINE_BASEURL}" \
  PF_RUN_PF_ENGINE_HOSTNAME="${PF_ENGINE_HOST}"

echo "PingFederate admin environment variables updated."

# Restart and wait for rollout
oc rollout status deployment/"${PF_ADMIN_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  --timeout=300s

# Verify environment variables
echo "Verifying PingFederate Engine environment..."

oc set env deployment/"${PF_ADMIN_DEPLOYMENT}" \
  -n "${NAMESPACE}" --list | grep PF_RUN_PF_

echo "=================================================="
echo "PingFedeerate Engine"
echo "=================================================="
PF_ENGINE_DEPLOYMENT="${RELEASE}-pingfederate-engine"

# Update environment variables
oc set env deployment/"${PF_ENGINE_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  PF_RUN_PF_ADMIN_BASEURL="${PF_ADMIN_BASEURL}" \
  PF_RUN_PF_ADMIN_HOSTNAME="${PF_ADMIN_HOST}" \
  PF_RUN_PF_ENGINE_BASEURL="${PF_ENGINE_BASEURL}" \
  PF_RUN_PF_ENGINE_HOSTNAME="${PF_ENGINE_HOST}"

echo "PingFederate Engine environment variables updated."

# Restart and wait for rollout
oc rollout status deployment/"${PF_ENGINE_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  --timeout=300s

# Verify environment variables
echo "Verifying PingFederate Engine environment..."

oc set env deployment/"${PF_ENGINE_DEPLOYMENT}" \
  -n "${NAMESPACE}" --list | grep PF_RUN_PF_

echo "==================================================="
echo "KeyCloak Deployment"
echo "==================================================="
oc process -f https://raw.githubusercontent.com/keycloak/keycloak-quickstarts/refs/heads/main/openshift/keycloak.yaml \
    -p KC_BOOTSTRAP_ADMIN_USERNAME=admin \
    -p KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
    -p NAMESPACE=keycloak \
| oc create -f -


