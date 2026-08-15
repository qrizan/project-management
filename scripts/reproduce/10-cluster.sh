#!/usr/bin/env bash
# Membuat cluster kind sesuai k8s/kind-cluster.yaml.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kind
need kubectl

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  fail "cluster '${CLUSTER_NAME}' sudah ada — jalankan 00-teardown.sh dulu"
fi

log "Membuat cluster kind '${CLUSTER_NAME}'"
kind create cluster --config "${REPO_ROOT}/k8s/kind-cluster.yaml"

log "Menunggu node siap"
kc wait --for=condition=Ready node --all --timeout="${WAIT_SHORT}"

kc get nodes
log "Cluster siap"
