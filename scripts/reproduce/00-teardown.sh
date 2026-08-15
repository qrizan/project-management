#!/usr/bin/env bash
# Menghapus seluruh keadaan yang dibuat script lain. Aman dijalankan walau tidak
# ada apa-apa untuk dihapus.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kind
need docker

log "Menghapus cluster kind '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "cluster tidak ada, dilewati"
fi

log "Menghapus container cloud-provider-kind"
docker rm -f cloud-provider-kind >/dev/null 2>&1 && echo "terhapus" || echo "tidak ada, dilewati"

# cloud-provider-kind menjalankan satu container Envoy terpisah per Service
# LoadBalancer. Container itu tidak selalu ikut terhapus saat clusternya hilang,
# dan sisanya akan memegang port serta membingungkan percobaan berikutnya.
log "Menghapus container LoadBalancer sisa (kindccm-*)"
leftovers="$(docker ps -aq --filter 'name=kindccm-')"
if [ -n "${leftovers}" ]; then
  # shellcheck disable=SC2086
  docker rm -f ${leftovers}
else
  echo "tidak ada, dilewati"
fi

log "Teardown selesai"
