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
retry 5 15 kc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kc wait --for=condition=Available deployment --all -n cert-manager --timeout="${WAIT_LONG}"

# Tanpa --rm, dengan --restart unless-stopped. Kalau container ini mati tanpa restart, 
# tidak ada jejaknya di Docker, dan gejalanya baru kelihatan belakangan
# sebagai Service LoadBalancer yang macet tanpa alamat.
log "cloud-provider-kind ${CLOUD_PROVIDER_KIND_VERSION}"
docker rm -f cloud-provider-kind >/dev/null 2>&1 || true
docker run -d --name cloud-provider-kind \
  --restart unless-stopped \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CLOUD_PROVIDER_KIND_VERSION}" \
  --gateway-channel disabled

# Manifest ini juga diterbitkan sebagai release asset (host github.com/.../releases/download/, 
# sama seperti cert-manager dan Barman Cloud Plugin di bawah), 
# bukan cuma lewat raw.githubusercontent.com. 
# Dipakai yang release asset karena raw.githubusercontent.com pernah kena rate limit
# (429) yang bertahan cukup lama di jaringan ini, sementara host release
# asset tidak pernah menunjukkan gejala itu.
log "CloudNativePG ${CNPG_VERSION}"
retry 5 15 kc apply --server-side \
  -f "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml"
kc rollout status deployment -n cnpg-system cnpg-controller-manager --timeout="${WAIT_LONG}"

log "Barman Cloud Plugin ${BARMAN_PLUGIN_VERSION}"
retry 5 15 kc apply -f "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${BARMAN_PLUGIN_VERSION}/manifest.yaml"
kc rollout status deployment -n cnpg-system barman-cloud --timeout="${WAIT_LONG}"

# Hook pre-install chart ini menarik image sendiri untuk membuat sertifikat internal, 
# dan bisa gagal karena timeout kalau jaringan lambat, meninggalkan rilis berstatus failed. 
# Rilis yang failed tidak bisa diperbarui lewat upgrade biasa, 
# jadi dibersihkan lebih dulu. 
# Rilis yang sehat cukup di-upgrade seperti komponen lain di script ini, 
# tidak perlu dibongkar pasang tiap kali script ini dijalankan ulang.
log "Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
if helm --kube-context "${KUBE_CONTEXT}" status eg -n envoy-gateway-system 2>/dev/null \
     | grep -q '^STATUS: failed'; then
  helm --kube-context "${KUBE_CONTEXT}" uninstall eg -n envoy-gateway-system
fi
helm --kube-context "${KUBE_CONTEXT}" upgrade --install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  -n envoy-gateway-system --create-namespace \
  --timeout "${WAIT_LONG}" --wait
kc wait --for=condition=Available deployment/envoy-gateway -n envoy-gateway-system --timeout="${WAIT_LONG}"

# Cluster-scoped, dipakai bersama oleh Gateway mana pun di cluster ini.
# Dipasang di sini, bukan ikut rilis aplikasi yang bisa dicabut sewaktu-waktu.
kc apply -f "${REPO_ROOT}/k8s/platform/gatewayclass.yaml"
kc wait --for=condition=Accepted gatewayclass/eg --timeout="${WAIT_SHORT}"

log "metrics-server"
kc apply -k "${REPO_ROOT}/k8s/platform/metrics-server"
kc rollout status deployment -n kube-system metrics-server --timeout="${WAIT_LONG}"
kc wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout="${WAIT_SHORT}"

log "Platform siap"
