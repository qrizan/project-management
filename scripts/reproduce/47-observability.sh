#!/usr/bin/env bash
# Memasang kube-prometheus-stack (Prometheus, Alertmanager, Grafana,
# kube-state-metrics, node-exporter) sebagai satu rilis Helm dari repo pihak
# ketiga, di namespace terpisah dari kedua rilis aplikasi.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need helm
need openssl
need docker
need kind
require_cluster
read_api_server_endpoint

log "Namespace ${MONITORING_NAMESPACE} (privileged, node-exporter butuh hostPath/hostNetwork/hostPID)"
kc apply -f "${REPO_ROOT}/k8s/observability/namespace.yaml"

create_secret_once "${MONITORING_NAMESPACE}" grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 20)"

# `--repo` langsung di `upgrade --install` mengunduh ulang index.yaml repo
# tiap kali dipanggil. Index-nya cukup besar dan pernah timeout di jaringan
# ini. `helm repo add` + `repo update` pakai jalur HTTP dengan batas waktu
# lebih longgar dan hasilnya di-cache lokal.
log "Menambahkan/memperbarui repo Helm prometheus-community"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null

# Cache Helm ada di host (~/.cache/helm), bukan di cluster kind, jadi tidak
# ikut terhapus --clean. Kalau repo update tetap gagal setelah beberapa kali
# coba, lanjut pakai cache lama, bukan menghentikan script: versi chart dipatok eksak, 
# jadi upgrade --install sendiri yang menentukan berhasil atau tidak.
repo_update_attempt=0
until helm repo update prometheus-community; do
  repo_update_attempt=$(( repo_update_attempt + 1 ))
  if [ "${repo_update_attempt}" -ge 3 ]; then
    log "helm repo update gagal ${repo_update_attempt}x, lanjut pakai cache lama di ~/.cache/helm"
    break
  fi
  printf '  ... percobaan %s gagal, coba lagi\n' "${repo_update_attempt}"
  sleep 10
done

# kube-prometheus-stack menarik banyak image sekaligus :
# (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, dan beberapa sidecar). 
# Dibiarkan kubelet menariknya sendiri-sendiri secara paralel,
# semuanya berebut bandwidth yang sama di jaringan yang lambat, 
# dan pernah membuat satu image kecil butuh waktu sangat lama, bukan karena ukurannya sendiri besar. 
#
# Ditarik satu-satu di host lalu dimuat ke node,
# pola yang sama seperti image PostgreSQL dan aplikasi di 40-app.sh.
#
# Daftar image diambil hanya dari dokumen yang kind-nya benar-benar
# menjalankan container (Deployment/StatefulSet/DaemonSet/Job/CronJob).
# Chart ini juga membuat ConfigMap berisi dashboard Grafana dan konfigurasi Alertmanager, 
# yang isinya teks bebas dan bisa saja memuat baris berbentuk
# "image:" tanpa hubungan dengan container manapun.
log "Menyiapkan image kube-prometheus-stack (ditarik satu-satu di host)"
images="$(helm template "${KUBE_PROMETHEUS_STACK_RELEASE}" prometheus-community/kube-prometheus-stack \
  --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
  --namespace "${MONITORING_NAMESPACE}" \
  -f "${REPO_ROOT}/k8s/observability/kube-prometheus-stack-values.yaml" \
  | awk '
      /^---$/ { keep = 0 }
      /^kind: (Deployment|StatefulSet|DaemonSet|Job|CronJob)$/ { keep = 1 }
      keep { print }
    ' \
  | grep -E '^[[:space:]]*(- )?image:' \
  | sed -E 's/^[[:space:]]*(- )?image:[[:space:]]*//; s/["'"'"']//g' \
  | sort -u)"
[ -n "${images}" ] || fail "tidak ada image terbaca dari render chart kube-prometheus-stack"
for img in ${images}; do
  docker pull "${img}"
  kind load docker-image --name "${CLUSTER_NAME}" "${img}"
done

log "kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION}"
helm --kube-context "${KUBE_CONTEXT}" upgrade --install "${KUBE_PROMETHEUS_STACK_RELEASE}" \
  prometheus-community/kube-prometheus-stack \
  --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
  --namespace "${MONITORING_NAMESPACE}" \
  -f "${REPO_ROOT}/k8s/observability/kube-prometheus-stack-values.yaml" \
  --timeout "${WAIT_LONG}"

# `kubectl wait` pada banyak Pod sekaligus tidak bisa diandalkan: 
# Pod yang sudah Ready sebelum watch-nya terpasang tetap dilaporkan "timed out". 
# Dipoll manual, dengan progres dicetak supaya penantian panjang tidak terlihat seperti macet.
#
# Dicek tanpa filter label. Pod Prometheus dan Alertmanager dibuat operator
# dari CRD, bukan langsung oleh Helm, jadi tidak ikut label instance chart.
# Namespace ini isinya cuma rilis ini, jadi mengecek seluruh Pod di namespace
# sama dengan mengecek seluruh Pod rilis ini.
log "Menunggu seluruh Pod monitoring siap"
deadline=$(( SECONDS + WAIT_LONG_SECS ))
while true; do
  total="$(kc get pods -n "${MONITORING_NAMESPACE}" --no-headers | wc -l)"
  not_ready="$(kc get pods -n "${MONITORING_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2 != "True" { printf "%s ", $1 }')"
  if [ "${total}" -ge 6 ] && [ -z "${not_ready}" ]; then
    break
  fi
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    fail "Pod monitoring belum Ready setelah ${WAIT_LONG}: ${not_ready}"
  fi
  printf '  ... belum Ready (%s/6 Pod ada): %s\n' "${total}" "${not_ready:-menunggu Pod muncul}"
  sleep 15
done

# Rilis "database" dipasang 40-app.sh, sebelum CRD monitoring.coreos.com ada
# di cluster ini. Template PodMonitor-nya menjaga diri sendiri lewat
# Capabilities.APIVersions.Has (lihat charts/database/templates/podmonitor.yaml),
# jadi rilis awal itu terpasang tanpa PodMonitor, bukan gagal. Di-upgrade ulang
# di sini, sekarang CRD-nya sudah ada (baru dipasang beberapa baris di atas),
# supaya PodMonitor menyusul terbentuk tanpa mengubah resource lain rilis ini.
log "Menyinkronkan ulang rilis database (PodMonitor, CRD-nya baru sekarang ada)"
helm_release database database "${DATABASE_VALUES_ARGS[@]}"

# Dashboard resmi proyek CNPG untuk metrik Cluster, diunduh sekali dari
# cloudnative-pg/grafana-dashboards lalu disunting: 32 panel dibuang (dari 114
# termasuk panel bersarang di row yang collapsed, jadi 82), seluruhnya karena
# bergantung pada metrik yang tidak akan pernah terisi di lingkungan ini,
# bukan sekadar kosong sementara. Tiga kelompok penyebab:
#   - kubelet_volume_stats_* (Storage & I/O, Volume Space Usage): PVC lewat
#     local-path-provisioner (StorageClass default kind) tidak mengimplementasikan
#     CSI NodeGetVolumeStats, jadi kubelet tidak pernah melaporkan statistik
#     per-PV, terlepas dari scraping.
#   - metrik operator (Operator row, panel Reconcile errors, panel Operator
#     Status, plus variabel dashboard operatorNamespace yang query-nya sendiri
#     butuh metrik operator): PodMonitor di sini sengaja cuma mencakup Pod
#     database (cnpg.io/cluster), bukan Pod operator cnpg-controller-manager,
#     jadi seluruh metrik controller_runtime_* dan turunannya (termasuk
#     variabel yang query-nya bergantung padanya) selalu kosong.
#   - replication lag per-koneksi (Replication row: Write/Flush/Replay Lag):
#     metriknya bersumber dari pg_stat_replication di sisi primary, yang
#     barisnya cuma ada kalau ada standby yang benar-benar terhubung. Cluster
#     ini satu instance, jadi tabel itu selalu kosong.
# Panel yang memakai metrik replication per-instance biasa (cnpg_pg_replication_lag,
# streaming_replicas, is_wal_receiver_up, in_recovery) DIPERTAHANKAN - metrik
# itu dihitung instance manager sendiri dan tetap terisi (bernilai 0) walau
# cluster cuma satu instance atau tidak ada standby terhubung, beda dari
# kubelet_volume_stats/controller_runtime_*/pg_stat_replication yang benar-benar
# tidak pernah ada.
# Disimpan sebagai file di repo, bukan diunduh fresh tiap provisioning seperti
# rencana semula - begitu isinya disunting, ini bukan lagi salinan upstream
# murni yang aman diganti otomatis.
#
# Sidecar grafana-sc-dashboard memantau ConfigMap berlabel grafana_dashboard=1
# di seluruh namespace (NAMESPACE: ALL pada konfigurasi chart), jadi
# penempatan di namespace monitoring bukan keharusan teknis, dipilih supaya
# berdekatan dengan Grafana yang memakainya.
#
# --server-side, bukan client-side (default): dashboard JSON-nya sendiri
# melebihi batas 262144 byte anotasi kubectl.kubernetes.io/last-applied-configuration
# yang dipakai client-side apply. Pola sama dengan CRD applicationsets.argoproj.io
# di 46-gitops.sh dan CRD CloudNativePG di 20-platform.sh.
log "Dashboard Grafana CNPG"
kc create configmap cnpg-grafana-dashboard -n "${MONITORING_NAMESPACE}" \
  --from-file=cnpg-cluster.json="${REPO_ROOT}/k8s/observability/cnpg-grafana-dashboard.json" \
  --dry-run=client -o yaml \
  | kc label --local -f - grafana_dashboard=1 -o yaml \
  | kc apply --server-side -f -

log "Monitoring terpasang"
helm --kube-context "${KUBE_CONTEXT}" list -n "${MONITORING_NAMESPACE}"
kc get pods -n "${MONITORING_NAMESPACE}"
