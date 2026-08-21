#!/usr/bin/env bash
# Pemeriksaan cepat orkestrasi, bisa gagal, bukan pengamatan manual. Seluruh
# pemeriksaan dijalankan sampai habis walau ada yang gagal, supaya satu kali
# jalan memberi gambaran penuh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need curl
need helm
require_cluster

read_api_server_endpoint

# Image Pod uji diambil dari chart, bukan ditulis ulang di sini, supaya tidak ada
# versi kembar yang bisa berbeda diam-diam.
PROBE_IMAGE="$(helm_rendered_value database imageName: "${DATABASE_VALUES_ARGS[@]}")"
[ -n "${PROBE_IMAGE}" ] || fail "image untuk Pod uji tidak terbaca dari chart database"

# Menjalankan Pod yang mencoba membuka satu koneksi TCP, lalu menyimpulkan dari isi lognya. 
# Keputusan sengaja tidak diambil dari sukses atau gagalnya Job:
# Job yang gagal karena sebab lain (image tidak ada, Pod ditolak Pod Security,
# salah argumen) tidak boleh terbaca sebagai bukti policy tidak menegakkan apa pun.
netpol_probe() {
  local ns="$1" name="$2" host="$3" port="$4" label="$5"
  kc delete job "${name}" -n "${ns}" --ignore-not-found >/dev/null
  kc apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: probe
        image: ${PROBE_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["/bin/bash", "-c"]
        args:
        - |
          if timeout 10 bash -c 'cat < /dev/null > /dev/tcp/${host}/${port}'; then
            echo REACHABLE
            exit 1
          fi
          echo BLOCKED
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
EOF
  local deadline=$(( SECONDS + 120 )) phase="" probe_log
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    phase="$(kc get pods -n "${ns}" -l "batch.kubernetes.io/job-name=${name}" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    case "${phase}" in Succeeded|Failed) break ;; esac
    sleep 5
  done
  probe_log="$(kc logs -n "${ns}" "job/${name}" --tail=20 2>/dev/null || true)"
  case "${probe_log}" in
    *BLOCKED*)   pass "${label}" ;;
    *REACHABLE*) bad "${label}: koneksi justru BERHASIL, policy tidak tertegakkan" ;;
    *)           bad "${label}: probe tidak melaporkan hasil (phase ${phase:-tidak diketahui}), kemungkinan probe-nya sendiri gagal jalan. Log: ${probe_log}" ;;
  esac
  kc delete job "${name}" -n "${ns}" --ignore-not-found >/dev/null
}

log "1. Seluruh Pod berjalan dan siap"
for ns in "${APP_NAMESPACE}" "${GARAGE_NAMESPACE}"; do
  # Jumlahnya diperiksa lebih dulu: daftar Pod bermasalah yang kosong juga
  # dihasilkan oleh namespace yang sama sekali tidak berisi Pod.
  total="$(kc get pods -n "${ns}" --no-headers 2>/dev/null | wc -l)"
  if [ "${total}" -eq 0 ]; then
    bad "namespace ${ns}: tidak ada Pod sama sekali"
    continue
  fi
  # `Running` belum berarti siap melayani; yang diperiksa condition Ready.
  # Pod Job yang sudah selesai berstatus Succeeded dengan Ready=False, itu
  # keadaan normal, bukan tidak sehat.
  unhealthy="$(kc get pods -n "${ns}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2 != "Succeeded" && $3 != "True" { printf "%s(%s) ", $1, $2 }')"
  if [ -z "${unhealthy}" ]; then
    pass "namespace ${ns} (${total} Pod)"
  else
    bad "namespace ${ns}, Pod belum siap: ${unhealthy}"
  fi
done

log "2. Pod Security restricted ditegakkan"
for ns in "${APP_NAMESPACE}" "${GARAGE_NAMESPACE}"; do
  actual="$(kc get ns "${ns}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
  check_eq "enforce di namespace ${ns}" "restricted" "${actual}"
done

log "3. Aplikasi dapat dijangkau lewat Gateway"
check_eq "HTTP /auth/signin lewat Gateway" "200" "$(gateway_http_code /auth/signin)"

log "4. metrics-server mengeluarkan angka"
if kc top pods -n "${APP_NAMESPACE}" >/dev/null 2>&1; then
  pass "kubectl top pods"
else
  bad "kubectl top pods tidak mengeluarkan metrik"
fi

log "5. HPA membaca metrik"
# Di-poll, bukan dibaca sekali: controller HPA baru mengisi status setelah sempat mengambil sampel, 
# sehingga pembacaan tepat setelah HPA dibuat selalu kosong tanpa ada yang salah.
hpa_target=""
hpa_deadline=$(( SECONDS + 180 ))
while [ "${SECONDS}" -lt "${hpa_deadline}" ]; do
  hpa_target="$(kc get hpa app -n "${APP_NAMESPACE}" \
    -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
  [ -n "${hpa_target}" ] && break
  sleep 10
done
if [ -n "${hpa_target}" ]; then
  pass "HPA membaca utilisasi CPU (${hpa_target}%)"
else
  bad "HPA tidak punya metrik setelah 3 menit, cek metrics-server"
fi

log "6. Data hasil seed"
check_eq "jumlah Project" "30" "$(psql_count postgres Project)"
check_eq "jumlah Category" "5" "$(psql_count postgres Category)"
check_eq "jumlah User" "1" "$(psql_count postgres User)"

# Pod uji dijalankan dari namespace lain, bukan dari namespace aplikasi.
# Aturan masuk Postgres cuma mengizinkan Pod berlabel `postgres-client` di
# namespace yang sama, jadi Pod dari luar pasti ditolak. 
# Sejak egress dibatasi, Pod tanpa label di namespace aplikasi akan terhenti di aturan
# keluar lebih dulu, sehingga hasilnya tidak bisa dikaitkan ke aturan masuk yang sedang diuji di sini.
log "7. Aturan masuk Postgres memblokir klien yang tidak diizinkan"
netpol_probe "${GARAGE_NAMESPACE}" netpol-ingress-probe \
  "postgres-rw.${APP_NAMESPACE}.svc.cluster.local" 5432 \
  "koneksi dari luar daftar klien diblokir"

log "8. WAL archiving berjalan"
# Backup manual yang sukses hanya membuktikan satu kali tulis ke object storage.
# Condition ini yang menyatakan arsip WAL berjalan terus-menerus.
archiving="$(kc get cluster postgres -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')"
check_eq "condition ContinuousArchiving" "True" "${archiving}"

log "9. Backup selesai"
if kc wait --for=jsonpath='{.status.phase}'=completed backup/postgres-backup-manual \
     -n "${APP_NAMESPACE}" --timeout="${WAIT_SHORT}" >/dev/null 2>&1; then
  pass "Backup postgres-backup-manual completed"
else
  bad "Backup tidak mencapai phase completed"
fi

# Pasangan pemeriksaan 7, dari dalam namespace aplikasi: Pod tanpa penanda
# klien tidak boleh bisa menjangkau database.
#
# Judulnya sengaja tidak menyebut aturan mana yang bekerja. Pod ini kena
# aturan masuk maupun aturan keluar sekaligus, jadi hasil "terblokir" tidak
# bisa dikaitkan ke salah satunya. Yang dijamin pemeriksaan ini adalah
# postur akhirnya, dan itu yang berlaku secara operasional.
#
# Menguji aturan keluar secara terpisah butuh tujuan dengan aturan masuk
# terbuka, dan tidak ada Pod semacam itu di namespace ini. Tujuan di luar
# namespace sudah dicoba dan ternyata tidak ditegakkan oleh CNI di
# lingkungan ini, jadi tidak bisa dipakai sebagai pembuktian.
log "10. Pod tanpa penanda klien tidak bisa menjangkau database"
netpol_probe "${APP_NAMESPACE}" netpol-egress-probe \
  "postgres-rw.${APP_NAMESPACE}.svc.cluster.local" 5432 \
  "koneksi ke database dari Pod tanpa penanda klien diblokir"

log "11. Namespace monitoring privileged (node-exporter, dikecualikan dari restricted)"
actual="$(kc get ns "${MONITORING_NAMESPACE}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
check_eq "enforce di namespace ${MONITORING_NAMESPACE}" "privileged" "${actual}"

# Diperiksa lewat API Prometheus, bukan cuma status Pod Running: Pod bisa
# Running tanpa satu pun scrape target-nya berhasil.
log "12. Prometheus men-scrape target di namespace aplikasi"
prom_svc="$(kc get svc -n "${MONITORING_NAMESPACE}" -l "app=${KUBE_PROMETHEUS_STACK_RELEASE}-prometheus" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
prom_query() {
  curl -fsS --max-time 10 -G \
    --data-urlencode "query=$1" \
    "http://127.0.0.1:19090/api/v1/query" | grep -q '"result":\[{'
}
if [ -z "${prom_svc}" ]; then
  bad "Service Prometheus tidak ditemukan di namespace ${MONITORING_NAMESPACE}"
elif with_port_forward "${MONITORING_NAMESPACE}" "${prom_svc}" 19090 9090 \
       prom_query "container_memory_working_set_bytes{namespace=\"${APP_NAMESPACE}\"}"; then
  pass "cAdvisor melaporkan memory Pod di namespace ${APP_NAMESPACE}"
else
  bad "Prometheus tidak punya sampel container_memory_working_set_bytes untuk namespace ${APP_NAMESPACE}"
fi

log "13. Dashboard Grafana tersedia"
grafana_svc="$(kc get svc -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
grafana_user="$(kc get secret grafana-admin -n "${MONITORING_NAMESPACE}" -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d)"
grafana_pass="$(kc get secret grafana-admin -n "${MONITORING_NAMESPACE}" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)"
grafana_query() {
  curl -fsS --max-time 10 -u "${grafana_user}:${grafana_pass}" \
    "http://127.0.0.1:19300/api/search?query=pod" | grep -qi '"title"'
}
if [ -z "${grafana_svc}" ] || [ -z "${grafana_user}" ]; then
  bad "Service atau kredensial Grafana tidak ditemukan di namespace ${MONITORING_NAMESPACE}"
elif with_port_forward "${MONITORING_NAMESPACE}" "${grafana_svc}" 19300 80 grafana_query; then
  pass "Grafana punya dashboard yang cocok kata kunci 'pod'"
else
  bad "Grafana tidak punya dashboard yang cocok kata kunci 'pod', atau tidak bisa dihubungi"
fi

# Diperiksa lewat metrik `up` Prometheus sendiri, bukan metrik data CNPG:
# metrik data bisa saja masih menyimpan sampel lama walau scrape saat ini
# sedang gagal, `up` mencerminkan hasil scrape yang paling baru.
log "14. Prometheus men-scrape target CNPG (PodMonitor)"
prom_query_up() {
  curl -fsS --max-time 10 -G \
    --data-urlencode "query=$1" \
    "http://127.0.0.1:19090/api/v1/query" | grep -q '"value":\[[0-9.]*,"1"\]'
}
if [ -z "${prom_svc}" ]; then
  bad "Service Prometheus tidak ditemukan di namespace ${MONITORING_NAMESPACE}"
elif with_port_forward "${MONITORING_NAMESPACE}" "${prom_svc}" 19090 9090 \
       prom_query_up "up{namespace=\"${APP_NAMESPACE}\", pod=~\"^postgres-.*\"}"; then
  pass "target CNPG PodMonitor berstatus up"
else
  bad "target CNPG PodMonitor tidak berstatus up (scrape gagal atau target tidak ditemukan)"
fi

# Diambil lewat uid, bukan pencarian kata kunci seperti check 13: kata kunci
# generik juga bisa cocok ke dashboard bawaan chart lain, uid membuktikan
# dashboard CNPG spesifik ini yang ada.
log "15. Dashboard Grafana CloudNativePG tersedia"
grafana_cnpg_query() {
  curl -fsS --max-time 10 -u "${grafana_user}:${grafana_pass}" \
    "http://127.0.0.1:19300/api/dashboards/uid/cloudnative-pg" | grep -q '"title":"CloudNativePG"'
}
if [ -z "${grafana_svc}" ] || [ -z "${grafana_user}" ]; then
  bad "Service atau kredensial Grafana tidak ditemukan di namespace ${MONITORING_NAMESPACE}"
elif with_port_forward "${MONITORING_NAMESPACE}" "${grafana_svc}" 19300 80 grafana_cnpg_query; then
  pass "Dashboard CloudNativePG (uid cloudnative-pg) ditemukan"
else
  bad "Dashboard CloudNativePG (uid cloudnative-pg) tidak ditemukan lewat API Grafana"
fi

log "Ringkasan"
if [ "${FAILED}" -eq 0 ]; then
  echo "Seluruh pemeriksaan cepat lolos."
  echo "Uji restore belum termasuk di sini, jalankan 60-restore-drill.sh."
else
  echo "${FAILED} pemeriksaan gagal."
  exit 1
fi
