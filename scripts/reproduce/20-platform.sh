#!/usr/bin/env bash
# Memasang komponen platform yang tidak spesifik aplikasi: cert-manager,
# cloud-provider-kind, operator CloudNativePG + plugin backup, Envoy Gateway,
# dan metrics-server.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need helm
need docker
require_cluster

log "cert-manager ${CERT_MANAGER_VERSION} (prasyarat Barman Cloud Plugin)"
kc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kc wait --for=condition=Available deployment --all -n cert-manager --timeout="${WAIT_LONG}"

# Dijalankan tanpa --rm dan dengan --restart unless-stopped. Sebelumnya proses
# ini pernah mati diam-diam dan baru ketahuan saat ada Service LoadBalancer yang
# macet tanpa alamat — tidak ada jejaknya di sisi Docker karena containernya ikut
# terhapus saat berhenti.
log "cloud-provider-kind ${CLOUD_PROVIDER_KIND_VERSION}"
docker rm -f cloud-provider-kind >/dev/null 2>&1 || true
docker run -d --name cloud-provider-kind \
  --restart unless-stopped \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CLOUD_PROVIDER_KIND_VERSION}" \
  --gateway-channel disabled

log "CloudNativePG ${CNPG_VERSION}"
kc apply --server-side \
  -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE_BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"
kc rollout status deployment -n cnpg-system cnpg-controller-manager --timeout="${WAIT_LONG}"

log "Barman Cloud Plugin ${BARMAN_PLUGIN_VERSION}"
kc apply -f "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${BARMAN_PLUGIN_VERSION}/manifest.yaml"
kc rollout status deployment -n cnpg-system barman-cloud --timeout="${WAIT_LONG}"

# Hook pre-install chart ini menarik image sendiri untuk membuat sertifikat
# internal. Timeout bawaan Helm 5 menit tidak cukup di jaringan ini dan
# meninggalkan rilis berstatus failed yang harus dibersihkan sebelum retry.
log "Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
if helm --kube-context "${KUBE_CONTEXT}" status eg -n envoy-gateway-system >/dev/null 2>&1; then
  helm --kube-context "${KUBE_CONTEXT}" uninstall eg -n envoy-gateway-system
fi
helm --kube-context "${KUBE_CONTEXT}" install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  -n envoy-gateway-system --create-namespace \
  --timeout "${WAIT_LONG}" --wait
kc wait --for=condition=Available deployment/envoy-gateway -n envoy-gateway-system --timeout="${WAIT_LONG}"

# Cluster-scoped dan dipakai bersama oleh Gateway mana pun di cluster ini, jadi
# dipasang di sini — bukan ikut rilis aplikasi yang bisa dicabut sewaktu-waktu.
kc apply -f "${REPO_ROOT}/k8s/platform/gatewayclass.yaml"
kc wait --for=condition=Accepted gatewayclass/eg --timeout="${WAIT_SHORT}"

log "metrics-server"
kc apply -k "${REPO_ROOT}/k8s/platform/metrics-server"
kc rollout status deployment -n kube-system metrics-server --timeout="${WAIT_LONG}"
kc wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout="${WAIT_SHORT}"

log "Platform siap"
