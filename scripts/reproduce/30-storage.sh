#!/usr/bin/env bash
# Memasang Garage sebagai object storage backup CloudNativePG.
#
# Kredensial S3 dibuat di sini dan disuntikkan ke Garage lewat env, bukan
# di-generate oleh Garage lalu disalin manual. Dengan begitu nilainya diketahui
# sejak awal dan bisa dipakai langsung oleh consumer di namespace lain.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need openssl
require_cluster

log "Namespace dan NetworkPolicy Garage"
kc apply -f "${REPO_ROOT}/k8s/garage/namespace.yaml"
kc apply -f "${REPO_ROOT}/k8s/garage/networkpolicy.yaml"

# Format access key mengikuti contoh dokumentasi Garage: awalan GK diikuti
# 32 karakter heksadesimal.
create_secret_once "${GARAGE_NAMESPACE}" garage-bootstrap \
  --from-literal=RPC_SECRET="$(openssl rand -hex 32)" \
  --from-literal=ADMIN_TOKEN="$(openssl rand -hex 32)" \
  --from-literal=ACCESS_KEY_ID="GK$(openssl rand -hex 16)" \
  --from-literal=SECRET_ACCESS_KEY="$(openssl rand -hex 32)"

log "Menerapkan manifest Garage"
kc apply -f "${REPO_ROOT}/k8s/garage/configmap.yaml"
kc apply -f "${REPO_ROOT}/k8s/garage/service.yaml"
kc apply -f "${REPO_ROOT}/k8s/garage/statefulset.yaml"

log "Menunggu Garage siap"
kc rollout status statefulset/garage -n "${GARAGE_NAMESPACE}" --timeout="${WAIT_LONG}"

log "Garage siap"
