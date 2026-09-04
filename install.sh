#!/usr/bin/env bash
#
# install.sh — install Trainy telemetry into your Kubernetes cluster.
#
# Installs the components that let Trainy see your GPU cluster's health:
#
#   metrics      the VictoriaMetrics operator and a VMAgent, which scrapes the
#                exporters your monitoring stack already defines and ships a
#                copy out. Your Prometheus is not modified or replaced.
#   logs         an OpenTelemetry DaemonSet, shipping pod logs from allowlisted
#                infrastructure namespaces only (default deny).
#   events       an OpenTelemetry Deployment, shipping Kubernetes events from
#                allowlisted namespaces plus all node events.
#   node health  the trainy-npd DaemonSet, running GPU/RDMA/PCIe/kernel checks
#                on GPU nodes, and the controller that acts on the results —
#                cordon, hand off for repair, validate, return to service.
#                Set NODE_HEALTH_MODE=detect for checks without the controller.
#   dmesg        a DaemonSet streaming each node's kernel ring buffer, which the
#                log shipper then forwards. Privileged; see manifests/dmesg.yaml.
#
# It does NOT install exporters. kube-state-metrics, node-exporter and the GPU
# metrics exporter belong to whoever runs your monitoring stack; this install
# reads them, and reports at preflight if any are missing.
#
# Everything is `helm upgrade --install` or `kubectl apply`: safe to re-run, and
# re-running with an edited config is how you change or upgrade an install.
#
# Usage:
#   cp trainy-telemetry.conf.example trainy-telemetry.conf   # then edit it
#   ./install.sh
#
#   ./install.sh -f /path/to/other.conf   use a different config file
#   ./install.sh -c my-cluster            override CUSTOMER from the config
#   ./install.sh --dry-run                print everything it would do, change nothing
#   ./install.sh --verify                 check an existing install, install nothing
#   ./install.sh --uninstall              remove everything this script installed
#
# Requires: kubectl, helm 3.8+ (OCI support), and cluster-admin on the target
# cluster. curl is used for an endpoint reachability check and is optional.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_DIR="$SCRIPT_DIR/values"
MANIFEST_DIR="$SCRIPT_DIR/manifests"
CONF_FILE="$SCRIPT_DIR/trainy-telemetry.conf"

DRY_RUN=false
VERIFY_ONLY=false
UNINSTALL=false
CUSTOMER_OVERRIDE=""
CONTEXT_OVERRIDE=""

# ------------------------------------------------------------------ defaults --
# Every key here can be overridden by the config file. Keeping the defaults in
# one place means a config file written against an older version of this script
# still works: keys it does not set simply keep these values.
CUSTOMER=""
KUBE_CONTEXT=""
METRICS_NAMESPACE="vm-operator"
OTEL_NAMESPACE="otel-collector"
NODE_HEALTH_NAMESPACE="trainy-system"
METRICS_ENDPOINT="https://o11y-ingest.konduktor.trainy.us/api/v1/write"
LOGS_ENDPOINT="https://o11y-ingest.konduktor.trainy.us/insert/opentelemetry/v1/logs"
INSTALL_METRICS="true"
INSTALL_LOGS="true"
INSTALL_EVENTS="true"
INSTALL_NODE_HEALTH="true"
INSTALL_DMESG="true"
DMESG_NAMESPACE="dmesg-logging"
DMESG_IMAGE="ubuntu:22.04"
MAX_SCRAPE_SIZE="134217728"
GPU_SCRAPE_INTERVAL="1s"
NODE_HEALTH_MODE="remediate"
DRAIN_POLICY="auto"
DESIRED_HEALTHY="1000"
REMEDIATION_MODE="Provider"
EXPECTED_GPUS="8"
RDMA_INTERFACES=""
IB_EXPECTED_ACTIVE_PORTS=""
GPU_VENDOR="nvidia"
GPU_NODE_SELECTOR="nvidia.com/gpu.present=true"
LOG_NAMESPACES="prometheus,monitoring,vm-operator,victoria-logs,otel-collector,gpu-operator,dmesg-logging,kube-system,mpi-operator,teleport,local-path-storage,network-operator,trainy-system,kueue-system,jobset-system,trainy-controller-system"
EVENT_NAMESPACES="prometheus,monitoring,vm-operator,victoria-logs,otel-collector,kube-system,mpi-operator,trainy-system,kueue-system,jobset-system,trainy-controller-system"
VM_OPERATOR_CHART_VERSION="0.67.2"
OTEL_LOGS_CHART_VERSION="0.131.0"
OTEL_EVENTS_CHART_VERSION="0.171.0"
NODE_HEALTH_CHART="oci://ghcr.io/trainy-ai/charts/trainy-remediation"
NODE_HEALTH_CHART_VERSION=""

# Helm release names, matching the reference install so support can read one
# `helm list` across every cluster.
REL_VM_OPERATOR="victoria-metrics-operator"
REL_LOGS="otel-central"
REL_EVENTS="otel-deployment-central"
REL_NODE_HEALTH="trainy-remediation"

# --------------------------------------------------------------------- output --
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
  C_BLU=$'\033[0;34m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi
info()  { echo "${C_BLU}==>${C_OFF} $*"; }
ok()    { echo "${C_GRN} ok${C_OFF} $*"; }
warn()  { echo "${C_YEL}warn${C_OFF} $*" >&2; }
die()   { echo "${C_RED}error${C_OFF} $*" >&2; exit 1; }
step()  { echo; echo "${C_BLU}=== $* ===${C_OFF}"; }

usage() { sed -n '3,/^# Requires/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0; }

# ----------------------------------------------------------------- arguments --
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--config)    CONF_FILE="$2"; shift 2 ;;
    -c|--customer)  CUSTOMER_OVERRIDE="$2"; shift 2 ;;
    -x|--context)   CONTEXT_OVERRIDE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --verify)       VERIFY_ONLY=true; shift ;;
    --uninstall)    UNINSTALL=true; shift ;;
    -h|--help)      usage ;;
    *)              die "unknown argument: $1 (try --help)" ;;
  esac
done

# --------------------------------------------------------------- config file --
# Parsed, not sourced: a config file cannot run commands. Unknown keys are a
# hard error rather than a silent no-op — a typo'd key in a file you edited by
# hand is a mistake you want to hear about now, not after a week of missing data.
KNOWN_KEYS="CUSTOMER KUBE_CONTEXT METRICS_NAMESPACE OTEL_NAMESPACE NODE_HEALTH_NAMESPACE \
METRICS_ENDPOINT LOGS_ENDPOINT \
INSTALL_METRICS INSTALL_LOGS INSTALL_EVENTS INSTALL_NODE_HEALTH \
INSTALL_DMESG DMESG_NAMESPACE DMESG_IMAGE \
MAX_SCRAPE_SIZE GPU_SCRAPE_INTERVAL \
NODE_HEALTH_MODE DRAIN_POLICY DESIRED_HEALTHY REMEDIATION_MODE \
EXPECTED_GPUS RDMA_INTERFACES IB_EXPECTED_ACTIVE_PORTS GPU_NODE_SELECTOR GPU_VENDOR \
LOG_NAMESPACES EVENT_NAMESPACES \
VM_OPERATOR_CHART_VERSION OTEL_LOGS_CHART_VERSION OTEL_EVENTS_CHART_VERSION \
NODE_HEALTH_CHART NODE_HEALTH_CHART_VERSION"

read_config() {
  local file="$1" line key value lineno=0
  [[ -f "$file" ]] || die "config file not found: $file
Copy the example and edit it:  cp trainy-telemetry.conf.example trainy-telemetry.conf"
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%$'\r'}"                       # tolerate CRLF
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *"="* ]] || die "$file:$lineno: not KEY=value: $line"
    key="${line%%=*}"; value="${line#*=}"
    key="$(echo "$key" | tr -d '[:space:]')"
    value="${value#"${value%%[![:space:]]*}"}"  # ltrim
    value="${value%"${value##*[![:space:]]}"}"  # rtrim
    value="${value#\"}"; value="${value%\"}"    # strip optional quotes
    value="${value#\'}"; value="${value%\'}"
    [[ " $KNOWN_KEYS " == *" $key "* ]] || die "$file:$lineno: unknown setting '$key'"
    printf -v "$key" '%s' "$value"
  done < "$file"
}

read_config "$CONF_FILE"
# Command-line flags are applied AFTER the config file, so -c/-x override it
# rather than the reverse.
if [[ -n "$CUSTOMER_OVERRIDE" ]]; then CUSTOMER="$CUSTOMER_OVERRIDE"; fi
if [[ -n "$CONTEXT_OVERRIDE" ]]; then KUBE_CONTEXT="$CONTEXT_OVERRIDE"; fi

# ------------------------------------------------------------------ wrappers --
k() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

# Every mutation goes through h() or kapply(), so --dry-run is honest: it prints
# the exact command and runs nothing.
h() {
  if $DRY_RUN; then
    printf '  helm'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} "$@"
}
h_read() { helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} "$@"; }

kapply() {
  local file="$1"
  if $DRY_RUN; then
    echo "  kubectl apply -f - <<'EOF'"
    sed 's/^/  /' "$file"
    echo "  EOF"
    return 0
  fi
  k apply -f "$file"
}

installed() { h_read status "$1" -n "$2" >/dev/null 2>&1; }

is_true() { [[ "${1,,}" == "true" || "${1,,}" == "yes" || "${1,,}" == "1" ]]; }

# Comma-separated list -> newline-separated, trimmed, empties dropped.
split_list() { echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true; }

TMPDIR_SELF="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SELF"' EXIT

# ================================================================= uninstall ==
if $UNINSTALL; then
  step "Uninstall"
  warn "This removes the Trainy telemetry releases. It does not touch your"
  warn "monitoring stack, your exporters, or any namespace it did not create."
  # The VMAgent CR is not Helm-managed and must go before the operator does —
  # afterwards there is nothing left to clear its finalizer.
  if [[ -n "$CUSTOMER" ]]; then
    k delete vmagent "vmagent-$CUSTOMER" -n "$METRICS_NAMESPACE" --ignore-not-found 2>/dev/null || true
    k delete secret vmagent-additional-scrape-configs -n "$METRICS_NAMESPACE" --ignore-not-found 2>/dev/null || true
  else
    warn "CUSTOMER not set — remove the VMAgent CR yourself BEFORE the operator:"
    warn "  kubectl -n $METRICS_NAMESPACE delete vmagent vmagent-<your-id>"
  fi
  k delete ds dmesg -n "$DMESG_NAMESPACE" --ignore-not-found 2>/dev/null || true
  for pair in "$REL_LOGS:$OTEL_NAMESPACE" "$REL_EVENTS:$OTEL_NAMESPACE" \
              "$REL_NODE_HEALTH:$NODE_HEALTH_NAMESPACE" "$REL_VM_OPERATOR:$METRICS_NAMESPACE"; do
    rel="${pair%%:*}"; ns="${pair##*:}"
    if installed "$rel" "$ns"; then
      info "uninstalling $rel (namespace $ns)"
      h uninstall "$rel" -n "$ns"
    fi
  done
  echo
  info "the '$DMESG_NAMESPACE' namespace is left in place; delete it if unused:"
  info "  kubectl delete namespace $DMESG_NAMESPACE"
  echo
  ok "Done. CRDs are left in place — Helm never removes them. To delete the"
  echo "   node-health CRDs explicitly:"
  echo "     kubectl delete crd noderemediations.trainy.ai nodepools.trainy.ai"
  exit 0
fi

# ================================================================== preflight ==
step "Preflight"

command -v kubectl >/dev/null || die "kubectl not found in PATH"
command -v helm    >/dev/null || die "helm not found in PATH (need 3.8+)"

info "helm $(helm version --template '{{.Version}}' 2>/dev/null || echo unknown)"

k version --request-timeout=15s >/dev/null 2>&1 \
  || die "cannot reach the cluster with context '${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || echo none)}'"
info "cluster: ${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || echo unknown)}"

if ! $VERIFY_ONLY; then
  [[ -n "$CUSTOMER" ]] || die "CUSTOMER is not set in $CONF_FILE.
This is the identifier Trainy assigned to your cluster; ask Trainy if you do
not have one. Everything you ship is filed under it."
  [[ "$CUSTOMER" != "CHANGEME" ]] || die "CUSTOMER is still CHANGEME in $CONF_FILE"
  [[ "$CUSTOMER" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || die "CUSTOMER must be lowercase letters, digits and dashes: got '$CUSTOMER'"
  info "customer: $CUSTOMER"
fi

case "$NODE_HEALTH_MODE" in
  detect|remediate) ;;
  *) die "NODE_HEALTH_MODE must be 'detect' or 'remediate', got '$NODE_HEALTH_MODE'" ;;
esac
case "$DRAIN_POLICY" in
  askApproval|auto|never) ;;
  *) die "DRAIN_POLICY must be askApproval, auto or never; got '$DRAIN_POLICY'" ;;
esac
case "$REMEDIATION_MODE" in
  Provider|InCluster) ;;
  *) die "REMEDIATION_MODE must be Provider or InCluster; got '$REMEDIATION_MODE'" ;;
esac
case "${GPU_VENDOR,,}" in
  nvidia|amd) GPU_VENDOR="${GPU_VENDOR,,}" ;;
  *) die "GPU_VENDOR must be 'nvidia' or 'amd'; got '$GPU_VENDOR'" ;;
esac

# The node selector has to match the vendor, and getting this wrong fails
# silently: the DaemonSet ends up with an unsatisfiable selector and schedules
# on zero nodes, which Kubernetes reports as a perfectly healthy 0/0.
if [[ "$GPU_VENDOR" == "amd" ]]; then
  if [[ "$GPU_NODE_SELECTOR" == "nvidia.com/gpu.present=true" ]]; then
    GPU_NODE_SELECTOR="feature.node.kubernetes.io/amd-gpu=true"
    info "GPU_VENDOR=amd — using the AMD node label ($GPU_NODE_SELECTOR)"
  elif [[ "$GPU_NODE_SELECTOR" == nvidia.com/* ]]; then
    die "GPU_VENDOR=amd but GPU_NODE_SELECTOR names an NVIDIA label ('$GPU_NODE_SELECTOR').
Set it to the label your AMD GPU nodes carry, e.g.
  GPU_NODE_SELECTOR=feature.node.kubernetes.io/amd-gpu=true"
  fi
fi

for f in "$VALUES_DIR/vm-operator.yaml" "$VALUES_DIR/otel-logs.yaml" \
         "$VALUES_DIR/otel-events.yaml" "$VALUES_DIR/node-health.yaml" \
         "$VALUES_DIR/node-health-amd.yaml" \
         "$MANIFEST_DIR/vmagent.yaml" "$MANIFEST_DIR/dmesg.yaml"; do
  [[ -f "$f" ]] || die "missing file: $f"
done

# Endpoint reachability. This catches the single most common failure: the
# install comes up perfectly healthy and ships nothing, because Trainy has not
# yet allowlisted this cluster's egress IP. Any HTTP response at all — including
# 4xx — proves the request reached the front door, which is what we are testing.
# Note this is checked from where YOU are running the script; if your laptop and
# your cluster egress from different addresses, the pods are the real test.
check_endpoint() {
  local url="$1" name="$2" code
  command -v curl >/dev/null || { warn "curl not found; skipping $name reachability check"; return 0; }
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST --data '' "$url" 2>/dev/null || echo 000)"
  if [[ "$code" == "000" ]]; then
    warn "$name endpoint unreachable from here: $url"
    warn "  Ask Trainy to allowlist your egress IP, or check outbound HTTPS/proxy rules."
    warn "  Continuing — the collectors will buffer and retry once it opens up."
  else
    ok "$name endpoint reachable (HTTP $code)"
  fi
}
if ! $VERIFY_ONLY; then
  if is_true "$INSTALL_METRICS"; then check_endpoint "$METRICS_ENDPOINT" metrics; fi
  if is_true "$INSTALL_LOGS" || is_true "$INSTALL_EVENTS"; then check_endpoint "$LOGS_ENDPOINT" logs; fi
fi

# ------------------------------------------------------- what already exists --
# This install ships what your monitoring stack already collects; it installs no
# exporters. So the inventory below is not a preference — a missing exporter is
# a hole in what Trainy can see, and only you can fill it.
have_ksm=false; have_nodeexp=false; have_dcgm=false
# Collected into variables before matching, deliberately. Piping kubectl
# straight into `grep -q` looks equivalent but is not: grep exits at the first
# match, kubectl dies of SIGPIPE, and under `set -o pipefail` the whole pipeline
# reports failure — so a cluster that DOES run the exporter gets reported as
# missing, but only when the output is large enough that kubectl is still
# writing. Silent, size-dependent, and exactly the kind of false "missing" that
# sends someone installing a duplicate exporter.
svc_all="$(k get svc -A --no-headers 2>/dev/null || true)"
svc_ksm="$(k get svc -A -l app.kubernetes.io/name=kube-state-metrics --no-headers 2>/dev/null || true)"
svc_nodeexp="$(k get svc -A -l 'app.kubernetes.io/name in (node-exporter,prometheus-node-exporter)' --no-headers 2>/dev/null || true)"
if [[ -n "$svc_ksm" ]]; then have_ksm=true; fi
if [[ -n "$svc_nodeexp" ]]; then have_nodeexp=true; fi
if grep -qE '(nvidia-)?dcgm-exporter|gpu-metrics-exporter|amd-(gpu|device)-metrics' <<< "$svc_all"; then have_dcgm=true; fi

SM_COUNT="$(k get servicemonitor -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
GPU_NODES="$(k get nodes -l "$GPU_NODE_SELECTOR" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

echo
info "cluster inventory"
echo "    GPU nodes ($GPU_NODE_SELECTOR): $GPU_NODES"
echo "    kube-state-metrics:   $($have_ksm && echo present || echo MISSING)"
echo "    node-exporter:        $($have_nodeexp && echo present || echo MISSING)"
echo "    GPU metrics exporter: $($have_dcgm && echo present || echo MISSING)"
echo "    ServiceMonitors:      $SM_COUNT"

if ! $have_ksm; then
  warn "kube-state-metrics is missing. This is the one that matters most: every"
  warn "  node health condition reaches Trainy as kube_node_status_condition"
  warn "  from kube-state-metrics. Without it the checks run and nobody sees them."
fi
if ! $have_nodeexp; then
  warn "node-exporter is missing — no CPU, memory, disk, network or InfiniBand"
  warn "  metrics. Ask whoever runs your monitoring stack to add it."
fi
if ! $have_dcgm; then
  warn "no GPU metrics exporter found — no per-GPU utilisation, temperature or"
  warn "  XID attribution. Usually enabled through your GPU operator."
fi
if [[ "$SM_COUNT" == "0" ]] && is_true "$INSTALL_METRICS"; then
  warn "no ServiceMonitors exist in this cluster. The VMAgent finds targets by"
  warn "  converting ServiceMonitors, so it would ship only the GPU job. If your"
  warn "  monitoring stack uses plain Prometheus scrape configs instead, tell"
  warn "  Trainy — the VMAgent needs static scrape configs adding."
fi
# The kernel logs only reach Trainy if the dmesg namespace is ALSO on the log
# allowlist — two settings that have to agree, in different sections of the
# config. Mismatched, the DaemonSet runs happily and ships nothing, which is
# indistinguishable from working until someone goes looking for an Xid.
if is_true "$INSTALL_DMESG" && is_true "$INSTALL_LOGS"; then
  if ! grep -qE "(^|,)[[:space:]]*${DMESG_NAMESPACE}[[:space:]]*(,|$)" <<< "$LOG_NAMESPACES"; then
    warn "DMESG_NAMESPACE ('$DMESG_NAMESPACE') is not in LOG_NAMESPACES — the kernel"
    warn "  logs would be collected on every node and then never shipped. Add it to"
    warn "  LOG_NAMESPACES, or set INSTALL_DMESG=false."
  fi
fi
if [[ "$GPU_NODES" == "0" ]] && is_true "$INSTALL_NODE_HEALTH"; then
  warn "no nodes match '$GPU_NODE_SELECTOR' — the node-health DaemonSet will have"
  warn "  nowhere to schedule. Set GPU_NODE_SELECTOR to the label your GPU nodes carry."
fi

# ===================================================================== verify ==
verify_install() {
  step "Verify"
  local failed=0
  check_rollout() {
    local kind="$1" name="$2" ns="$3" label="$4"
    if ! k get "$kind" "$name" -n "$ns" >/dev/null 2>&1; then
      echo "    $label: not installed"
      return 0
    fi
    if k rollout status "$kind/$name" -n "$ns" --timeout=180s >/dev/null 2>&1; then
      ok "$label"
    else
      echo "${C_RED}fail${C_OFF} $label — kubectl describe $kind/$name -n $ns"
      failed=1
    fi
  }
  check_rollout deploy "$REL_VM_OPERATOR" "$METRICS_NAMESPACE" "VictoriaMetrics operator"
  if [[ -n "$CUSTOMER" ]]; then
    check_rollout deploy "vmagent-vmagent-$CUSTOMER" "$METRICS_NAMESPACE" "metrics shipper (VMAgent)"
  fi
  check_rollout ds     "$REL_LOGS-agent" "$OTEL_NAMESPACE" "log shipper"
  check_rollout deploy "$REL_EVENTS"     "$OTEL_NAMESPACE" "event shipper"
  check_rollout ds     dmesg "$DMESG_NAMESPACE" "kernel logs (dmesg)"
  check_rollout ds     "$REL_NODE_HEALTH-trainy-remediation-npd" "$NODE_HEALTH_NAMESPACE" "node health checks"
  if [[ "$NODE_HEALTH_MODE" == "remediate" ]]; then
    check_rollout deploy "$REL_NODE_HEALTH-trainy-remediation" "$NODE_HEALTH_NAMESPACE" "remediation controller"
  fi

  echo
  info "node health conditions currently published"
  local conds
  conds="$(k get nodes -o json 2>/dev/null \
    | grep -o '"type": *"trainy\.ai/[^"]*"' | sed 's/.*"trainy.ai\//  trainy.ai\//; s/"$//' \
    | sort -u || true)"
  if [[ -n "$conds" ]]; then
    echo "$conds" | head -40
  else
    echo "    none yet — the checks take up to a couple of minutes on first start."
  fi

  echo
  if [[ "$failed" == "0" ]]; then
    ok "all installed components are healthy"
  else
    warn "some components are unhealthy — see above"
    return 1
  fi
}

if $VERIFY_ONLY; then
  verify_install
  exit $?
fi

# ================================================================ helm repos ==
step "Helm repositories"
h_read repo add vm https://victoriametrics.github.io/helm-charts/ >/dev/null 2>&1 || true
h_read repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
h_read repo update vm open-telemetry >/dev/null
ok "repositories up to date"

if $DRY_RUN; then echo; warn "DRY RUN — the commands below are printed, not run."; fi

# =================================================================== metrics ==
if is_true "$INSTALL_METRICS"; then
  step "Metrics: VictoriaMetrics operator"
  h upgrade --install "$REL_VM_OPERATOR" vm/victoria-metrics-operator \
    --namespace "$METRICS_NAMESPACE" --create-namespace \
    ${VM_OPERATOR_CHART_VERSION:+--version "$VM_OPERATOR_CHART_VERSION"} \
    --values "$VALUES_DIR/vm-operator.yaml" \
    --wait --timeout 10m

  step "Metrics: VMAgent"
  # Fixed-token substitution rather than envsubst: the manifest carries
  # Prometheus relabel syntax (${1} back-references) that envsubst would eat.
  VMAGENT_RENDERED="$TMPDIR_SELF/vmagent.yaml"
  sed -e "s|__CUSTOMER__|$CUSTOMER|g" \
      -e "s|__NAMESPACE__|$METRICS_NAMESPACE|g" \
      -e "s|__METRICS_ENDPOINT__|$METRICS_ENDPOINT|g" \
      -e "s|__MAX_SCRAPE_SIZE__|$MAX_SCRAPE_SIZE|g" \
      -e "s|__GPU_SCRAPE_INTERVAL__|$GPU_SCRAPE_INTERVAL|g" \
      "$MANIFEST_DIR/vmagent.yaml" > "$VMAGENT_RENDERED"
  if grep -q '__[A-Z_]*__' "$VMAGENT_RENDERED"; then
    die "unsubstituted placeholder in the VMAgent manifest: $(grep -o '__[A-Z_]*__' "$VMAGENT_RENDERED" | sort -u | tr '\n' ' ')"
  fi

  # The operator must have registered the VMAgent CRD before the CR will apply.
  if ! $DRY_RUN; then
    for _ in $(seq 1 30); do
      k get crd vmagents.operator.victoriametrics.com >/dev/null 2>&1 && break
      sleep 2
    done
  fi
  kapply "$VMAGENT_RENDERED"
fi

# ====================================================================== logs ==
# The namespace allowlist is enforced in two places that must agree (the filelog
# globs and the filter regex). Rendering both from one list here is the whole
# reason this script exists rather than a page of helm commands: edited by hand,
# those two lists drift, and the drift is silent in both directions.
if is_true "$INSTALL_LOGS"; then
  step "Log shipper"
  LOG_NS="$(split_list "$LOG_NAMESPACES")"
  [[ -n "$LOG_NS" ]] || die "LOG_NAMESPACES is empty — nothing would be collected"
  LOG_OVERLAY="$TMPDIR_SELF/logs-allowlist.yaml"
  {
    echo "# Generated by install.sh from LOG_NAMESPACES — do not edit by hand."
    echo "config:"
    echo "  receivers:"
    echo "    filelog:"
    echo "      include:"
    while IFS= read -r ns; do echo "        - /var/log/pods/${ns}_*/*/*.log"; done <<< "$LOG_NS"
    echo "  processors:"
    echo "    filter/trainy_namespaces:"
    echo "      logs:"
    echo "        log_record:"
    printf '          - %s\n' "'resource.attributes[\"k8s.namespace.name\"] == nil'"
    printf '          - %s\n' "'not IsMatch(resource.attributes[\"k8s.namespace.name\"], \"^($(echo "$LOG_NS" | paste -sd '|' -))$\")'"
  } > "$LOG_OVERLAY"

  info "log namespaces: $(echo "$LOG_NS" | paste -sd , - | sed 's/,/, /g')"
  if $DRY_RUN; then echo "  --- generated allowlist overlay ---"; sed 's/^/  /' "$LOG_OVERLAY"; fi

  h upgrade --install "$REL_LOGS" open-telemetry/opentelemetry-collector \
    --namespace "$OTEL_NAMESPACE" --create-namespace \
    ${OTEL_LOGS_CHART_VERSION:+--version "$OTEL_LOGS_CHART_VERSION"} \
    --values "$VALUES_DIR/otel-logs.yaml" \
    --values "$LOG_OVERLAY" \
    --set-string "config.processors.resource/customer.attributes[0].value=$CUSTOMER" \
    --set-string "config.exporters.otlphttp/central.logs_endpoint=$LOGS_ENDPOINT" \
    --wait --timeout 10m
fi

# ==================================================================== events ==
if is_true "$INSTALL_EVENTS"; then
  step "Event shipper"
  EVENT_NS="$(split_list "$EVENT_NAMESPACES")"
  [[ -n "$EVENT_NS" ]] || die "EVENT_NAMESPACES is empty — nothing would be collected"
  EVENT_OVERLAY="$TMPDIR_SELF/events-allowlist.yaml"
  {
    echo "# Generated by install.sh from EVENT_NAMESPACES — do not edit by hand."
    echo "config:"
    echo "  receivers:"
    echo "    k8sobjects:"
    echo "      objects:"
    echo "        - name: events"
    echo "          mode: watch"
    echo "          group: events.k8s.io"
    echo "          exclude_watch_type: [DELETED]"
    echo "          namespaces:"
    while IFS= read -r ns; do echo "            - $ns"; done <<< "$EVENT_NS"
    # Node events, scoped by object kind rather than namespace — see
    # values/otel-events.yaml for why this is not simply another namespace.
    echo "        - name: events"
    echo "          mode: watch"
    echo "          exclude_watch_type: [DELETED]"
    echo "          field_selector: involvedObject.kind=Node"
  } > "$EVENT_OVERLAY"

  info "event namespaces: $(echo "$EVENT_NS" | paste -sd , - | sed 's/,/, /g') (+ all node events)"
  if $DRY_RUN; then echo "  --- generated allowlist overlay ---"; sed 's/^/  /' "$EVENT_OVERLAY"; fi

  h upgrade --install "$REL_EVENTS" open-telemetry/opentelemetry-collector \
    --namespace "$OTEL_NAMESPACE" --create-namespace \
    ${OTEL_EVENTS_CHART_VERSION:+--version "$OTEL_EVENTS_CHART_VERSION"} \
    --values "$VALUES_DIR/otel-events.yaml" \
    --values "$EVENT_OVERLAY" \
    --set-string "config.processors.resource/customer.attributes[0].value=$CUSTOMER" \
    --set-string "config.exporters.otlphttp/central.logs_endpoint=$LOGS_ENDPOINT" \
    --wait --timeout 10m
fi

# ====================================================================== dmesg ==
if is_true "$INSTALL_DMESG"; then
  step "Kernel logs (dmesg)"
  DMESG_RENDERED="$TMPDIR_SELF/dmesg.yaml"
  sed -e "s|__NAMESPACE__|$DMESG_NAMESPACE|g" \
      -e "s|__IMAGE__|$DMESG_IMAGE|g" \
      "$MANIFEST_DIR/dmesg.yaml" > "$DMESG_RENDERED"
  if grep -q '__[A-Z_]*__' "$DMESG_RENDERED"; then
    die "unsubstituted placeholder in the dmesg manifest: $(grep -o '__[A-Z_]*__' "$DMESG_RENDERED" | sort -u | tr '\n' ' ')"
  fi
  info "privileged DaemonSet on every node — see manifests/dmesg.yaml for why"
  kapply "$DMESG_RENDERED"
fi

# =============================================================== node health ==
if is_true "$INSTALL_NODE_HEALTH"; then
  NH_OVERLAY="$TMPDIR_SELF/node-health.yaml"
  NH_KEY="${GPU_NODE_SELECTOR%%=*}"
  NH_VAL="${GPU_NODE_SELECTOR#*=}"

  {
    echo "# Generated by install.sh — hardware and mode settings from your config."
    echo "expectedGpus: $EXPECTED_GPUS"
    echo "npd:"
    echo "  nodeSelector:"
    echo "    $NH_KEY: \"$NH_VAL\""
    if [[ -n "$RDMA_INTERFACES" || -n "$IB_EXPECTED_ACTIVE_PORTS" ]]; then
      echo "  env:"
      if [[ -n "$RDMA_INTERFACES" ]]; then
        echo "    - name: RDMA_INTERFACES"
        echo "      value: \"$RDMA_INTERFACES\""
      fi
      if [[ -n "$IB_EXPECTED_ACTIVE_PORTS" ]]; then
        echo "    - name: IB_EXPECTED_ACTIVE_PORTS"
        echo "      value: \"$IB_EXPECTED_ACTIVE_PORTS\""
      fi
    fi
    echo "remediation:"
    echo "  mode: $REMEDIATION_MODE"
    if [[ "$NODE_HEALTH_MODE" == "remediate" ]]; then
      echo "controller:"
      echo "  enabled: true"
      echo "drainPolicy: $DRAIN_POLICY"
      echo "nodePools:"
      echo "  - name: gpu-pool"
      echo "    desiredHealthy: ${DESIRED_HEALTHY:-$GPU_NODES}"
      echo "    nodeSelector:"
      echo "      $NH_KEY: \"$NH_VAL\""
    else
      # Detection only: no controller, and no node pool — nothing would
      # reconcile one.
      echo "controller:"
      echo "  enabled: false"
    fi
  } > "$NH_OVERLAY"

  # AMD clusters load a different check set entirely — no Xid, no DCGM, no
  # NVLink — and must not inherit the NVIDIA node label. See the overlay.
  NH_VENDOR_VALUES=""
  if [[ "$GPU_VENDOR" == "amd" ]]; then
    NH_VENDOR_VALUES="$VALUES_DIR/node-health-amd.yaml"
  fi

  if [[ "$NODE_HEALTH_MODE" == "remediate" ]]; then
    step "Node health (detection + auto-remediation)"
    warn "remediate mode: the controller may cordon, drain and repair GPU nodes."
    warn "  drain policy: $DRAIN_POLICY   repair mode: $REMEDIATION_MODE   vendor: $GPU_VENDOR"
  else
    step "Node health (detection only)"
  fi
  if $DRY_RUN; then echo "  --- generated node-health overlay ---"; sed 's/^/  /' "$NH_OVERLAY"; fi

  # Resolve the chart before installing, so a registry or version problem is a
  # clear message here rather than a Helm error mid-install. If no stable
  # version resolves, fall back to the latest development build (--devel) and
  # say so out loud: the checks are the same, but the version moves with every
  # merge, so pin NODE_HEALTH_CHART_VERSION once you have one that suits you.
  NH_DEVEL=""; NH_RESOLVED=""; NH_DIGEST=""
  # Resolve what the chart reference actually points at RIGHT NOW. helm prints
  # the chart YAML on stdout and the "Pulled:"/"Digest:" lines on stderr, so
  # both streams have to be captured separately to get version and digest.
  resolve_chart_meta() {
    local out="$TMPDIR_SELF/chart.out" err="$TMPDIR_SELF/chart.err"
    helm show chart "$NODE_HEALTH_CHART" "$@" >"$out" 2>"$err" || return 1
    NH_RESOLVED="$(sed -n 's/^version: //p' "$out" | head -1)"
    NH_DIGEST="$(sed -n 's/^Digest: //p' "$err" | head -1)"
    return 0
  }

  if [[ -d "$NODE_HEALTH_CHART" ]]; then
    info "node-health chart: local path $NODE_HEALTH_CHART"
  elif resolve_chart_meta ${NODE_HEALTH_CHART_VERSION:+--version "$NODE_HEALTH_CHART_VERSION"}; then
    info "node-health chart: ${NH_RESOLVED:-${NODE_HEALTH_CHART_VERSION:-latest release}}${NH_DIGEST:+ (${NH_DIGEST})}"
  elif [[ -z "$NODE_HEALTH_CHART_VERSION" ]] && resolve_chart_meta --devel; then
    NH_DEVEL="--devel"
    warn "no tagged release of the node-health chart is published yet;"
    warn "  using the latest development build: ${NH_RESOLVED:-unknown}"
    warn ""
    warn "  This reference moves with every merge to main — two installs a day"
    warn "  apart get different builds. Pin one of these in your config:"
    warn ""
    if [[ -n "$NH_DIGEST" ]]; then
      # The digest cannot move, even if a tag is re-pushed. Prefer it.
      warn "    NODE_HEALTH_CHART=${NODE_HEALTH_CHART}@${NH_DIGEST}"
      warn "    NODE_HEALTH_CHART_VERSION="
      warn ""
      warn "  or, less strictly, by version:"
    fi
    warn "    NODE_HEALTH_CHART_VERSION=${NH_RESOLVED:-<version>}"
  else
    die "cannot pull the node-health chart: $NODE_HEALTH_CHART ${NODE_HEALTH_CHART_VERSION:-}
Check outbound access to ghcr.io, or ask Trainy for a version to pin.
To install from a repository checkout instead, set in your config:
  NODE_HEALTH_CHART=/path/to/konduktor/charts/trainy-remediation"
  fi

  h upgrade --install "$REL_NODE_HEALTH" "$NODE_HEALTH_CHART" \
    --namespace "$NODE_HEALTH_NAMESPACE" --create-namespace \
    ${NODE_HEALTH_CHART_VERSION:+--version "$NODE_HEALTH_CHART_VERSION"} $NH_DEVEL \
    --values "$VALUES_DIR/node-health.yaml" \
    ${NH_VENDOR_VALUES:+--values "$NH_VENDOR_VALUES"} \
    --values "$NH_OVERLAY" \
    --wait --timeout 15m

  # Remediation taints a node it is repairing with trainy.ai/node-state. The GPU
  # operator's own DaemonSets must tolerate that taint, or a node under repair
  # loses its device plugin, reports zero allocatable GPUs, and can never pass
  # the post-repair validation that would return it to service. Patched on the
  # ClusterPolicy rather than through your GPU operator's Helm values, so this
  # works whoever owns that release — which also means a later `helm upgrade` of
  # the GPU operator wipes it. Re-run this script after any such upgrade.
  if [[ "$NODE_HEALTH_MODE" == "remediate" ]] && ! $DRY_RUN; then
    CP="$(k get clusterpolicy -o name 2>/dev/null | head -1 || true)"
    if [[ -n "$CP" ]]; then
      info "patching $CP to tolerate the node-state taint"
      k patch "$CP" --type merge -p '{"spec":{"daemonsets":{"tolerations":[
        {"effect":"NoSchedule","key":"nvidia.com/gpu","operator":"Exists"},
        {"effect":"NoSchedule","key":"trainy.ai/node-state","operator":"Exists"}]}}}' >/dev/null
    else
      warn "no GPU operator ClusterPolicy found — if your GPU DaemonSets do not"
      warn "  tolerate trainy.ai/node-state, nodes under repair will report 0 GPUs."
    fi
  fi
fi

# ===================================================================== done ===
if $DRY_RUN; then
  echo; ok "dry run complete — nothing was changed."
  exit 0
fi

verify_install || true

cat <<EOF

$(printf '%s' "${C_GRN}")Installed.${C_OFF} This cluster now ships telemetry to Trainy as customer="$CUSTOMER".

What to do next:

  1. Tell Trainy the install is up. They will confirm your data is arriving and
     that ingest is allowlisted for your egress IP — until it is, the collectors
     buffer locally and retry, and nothing reaches them.

  2. Fill any exporter gaps reported at the top of this run. Node health
     conditions reach Trainy through kube-state-metrics; without it the checks
     run and nobody sees the results.

  3. Re-check health any time, without changing anything:
       $0 --verify

  4. Change what is shipped by editing $CONF_FILE and re-running $0.
     To remove everything: $0 --uninstall

Local sanity checks:

  kubectl -n $METRICS_NAMESPACE get pods
  kubectl -n $METRICS_NAMESPACE logs deploy/vmagent-vmagent-$CUSTOMER --tail=20
  kubectl -n $OTEL_NAMESPACE get pods
  kubectl get nodes -o json | grep -o '"type": *"trainy\.ai/[^"]*"' | sort -u
EOF
