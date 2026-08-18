#!/usr/bin/env bash
# Membuktikan alert rule benar-benar bisa dipicu: menerapkan PrometheusRule,
# memaksa container app restart, lalu memeriksa lewat API Prometheus bahwa
# alert-nya berpindah ke status firing, bukan cuma rule-nya ada di cluster.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need curl
require_cluster

log "Menerapkan PrometheusRule app-restart-demo"
kc apply -f "${REPO_ROOT}/k8s/observability/alert-rule.yaml"

prom_svc="$(kc get svc -n "${MONITORING_NAMESPACE}" -l "app=${KUBE_PROMETHEUS_STACK_RELEASE}-prometheus" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${prom_svc}" ] || fail "Service Prometheus tidak ditemukan, jalankan 47-observability.sh dulu"

# Kalau script sebelumnya berhenti tanpa sempat membersihkan diri, proses
# port-forward lama bisa masih menahan port ini, membuat bind baru gagal
# diam-diam atau tetap meneruskan ke Pod lama yang sudah tidak melayani.
# Dibersihkan dulu sebelum membuka yang baru.
pkill -f "port-forward.*19090:9090" 2>/dev/null || true
sleep 1

# Satu port-forward dipakai untuk seluruh langkah, bukan dibuka-tutup tiap kali cek. 
# Membuka port-forward baru per pemeriksaan memakan waktu (sampai 30 detik nunggu siap tiap kali) 
# dan mengurangi jatah waktu tunggu yang sebenarnya.
#
# stderr ditangkap ke file, bukan dibuang, supaya kegagalan bind atau koneksi
# terputus terlihat kalau ready check di bawah gagal, bukan cuma pesan generik.
pf_log="$(mktemp)"
kc port-forward "svc/${prom_svc}" 19090:9090 -n "${MONITORING_NAMESPACE}" >"${pf_log}" 2>&1 &
pf_pid=$!
trap 'kill "${pf_pid}" 2>/dev/null || true; wait "${pf_pid}" 2>/dev/null || true; rm -f "${pf_log}"' EXIT

log "Menunggu Prometheus siap dijangkau lewat port-forward"
deadline=$(( SECONDS + 30 ))
ready=1
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:19090/-/ready" 2>/dev/null; then
    ready=0
    break
  fi
  sleep 1
done
if [ "${ready}" -ne 0 ]; then
  echo "--- log port-forward:" >&2
  cat "${pf_log}" >&2
  fail "Prometheus tidak menjawab lewat port-forward"
fi

# Pod Ready (dicek 47-observability.sh) tidak berarti Prometheus operator
# sudah memuat ServiceMonitor dan Prometheus sudah benar-benar men-scrape
# kube-state-metrics - yang merupakan proses terpisah yang butuh waktu sendiri. 
# 
# Restart dipicu sebelum scrape ini jalan, restart count yang naik tidak akan
# pernah kelihatan sampai window [5m] sudah lewat duluan. Ditunggu di sini,
# sebelum Pod app direstart, bukan diasumsikan sudah siap.
log "Menunggu Prometheus men-scrape restart count aplikasi"
scrape_deadline=$(( SECONDS + 120 ))
scraping=1
while [ "${SECONDS}" -lt "${scrape_deadline}" ]; do
  if curl -fsS --max-time 10 -G \
       --data-urlencode "query=kube_pod_container_status_restarts_total{namespace=\"${APP_NAMESPACE}\",container=\"app\"}" \
       "http://127.0.0.1:19090/api/v1/query" 2>/dev/null | grep -q '"result":\[{'; then
    scraping=0
    break
  fi
  sleep 5
done
[ "${scraping}" -eq 0 ] || fail "Prometheus belum punya sampel kube_pod_container_status_restarts_total untuk container app setelah 2 menit"

log "Memaksa container app restart"
# `kill` bukan biner tersendiri di image runner, dipanggil sebagai builtin
# shell lewat sh -c, bukan dieksekusi langsung.
kc exec -n "${APP_NAMESPACE}" deploy/app -c app -- sh -c 'kill 1' \
  || fail "gagal mengirim kill ke Pod app, cek apakah Deployment app ada (jalankan 40-app.sh dulu)"

log "Menunggu alert AppPodRestartingDemo firing (sampai 5 menit)"
deadline=$(( SECONDS + 300 ))
fired=1
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if curl -fsS --max-time 10 "http://127.0.0.1:19090/api/v1/alerts" 2>/dev/null \
       | grep -A2 '"alertname":"AppPodRestartingDemo"' | grep -q '"state":"firing"'; then
    fired=0
    break
  fi
  sleep 10
done

if [ "${fired}" -eq 0 ]; then
  echo "Alert AppPodRestartingDemo firing, terbukti."
else
  fail "Alert AppPodRestartingDemo tidak firing setelah 5 menit, cek apakah PrometheusRule terpilih operator (label release) dan apakah restart count benar-benar naik"
fi
