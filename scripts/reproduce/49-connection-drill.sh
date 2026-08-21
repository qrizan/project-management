#!/usr/bin/env bash
# Membuktikan metrik koneksi CNPG (cnpg_backends_total) benar-benar naik
# mengikuti kondisi koneksi yang dipicu sungguhan, bukan cuma exporter-nya ada.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need curl
require_cluster
read_api_server_endpoint

PROBE_IMAGE="$(helm_rendered_value database imageName: "${DATABASE_VALUES_ARGS[@]}")"
[ -n "${PROBE_IMAGE}" ] || fail "image untuk Pod drill tidak terbaca dari chart database"

DB_HOST="$(kc get secret postgres-app -n "${APP_NAMESPACE}" -o jsonpath='{.data.host}' | base64 -d)"
[ -n "${DB_HOST}" ] || fail "Secret postgres-app tidak ditemukan atau field host kosong, jalankan 40-app.sh dulu"

# 70, bukan mendekati max_connections (100, dipatok Postgres): cukup jauh dari
# superuser_reserved_connections dan pemakaian operator/aplikasi yang mungkin
# berjalan bersamaan, tapi tetap jauh di atas baseline (biasanya cuma
# beberapa) sehingga kenaikannya tidak ambigu. Ambang 60, bukan 70, supaya
# beberapa koneksi yang gagal karena alasan lain tidak menggagalkan drill.
TARGET_CONNECTIONS=70
SUCCESS_THRESHOLD=60

prom_svc="$(kc get svc -n "${MONITORING_NAMESPACE}" -l "app=${KUBE_PROMETHEUS_STACK_RELEASE}-prometheus" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${prom_svc}" ] || fail "Service Prometheus tidak ditemukan, jalankan 47-observability.sh dulu"

pkill -f "port-forward.*19093:9090" 2>/dev/null || true
sleep 1

pf_log="$(mktemp)"
kc port-forward "svc/${prom_svc}" 19093:9090 -n "${MONITORING_NAMESPACE}" >"${pf_log}" 2>&1 &
pf_pid=$!
# Job dihapus di sini, bukan dibiarkan habis sendiri lewat pg_sleep: durasi
# koneksi terbuka dikendalikan script (berhenti begitu hasilnya terbukti atau
# timeout), bukan angka tetap yang ditebak.
trap 'kc delete job cnpg-connection-drill -n "${APP_NAMESPACE}" --ignore-not-found >/dev/null 2>&1; kill "${pf_pid}" 2>/dev/null || true; wait "${pf_pid}" 2>/dev/null || true; rm -f "${pf_log}"' EXIT

log "Menunggu Prometheus siap dijangkau lewat port-forward"
deadline=$(( SECONDS + 30 ))
ready=1
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:19093/-/ready" 2>/dev/null; then
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

backends_now() {
  curl -fsS --max-time 10 -G \
    --data-urlencode "query=sum(cnpg_backends_total{namespace=\"${APP_NAMESPACE}\", pod=~\"^postgres-.*\"})" \
    "http://127.0.0.1:19093/api/v1/query" 2>/dev/null \
    | grep -oP '"value":\[[0-9.]+,"\K[0-9.]+' || true
}

log "Mengukur baseline cnpg_backends_total sebelum drill"
baseline=""
scrape_deadline=$(( SECONDS + 120 ))
while [ "${SECONDS}" -lt "${scrape_deadline}" ]; do
  baseline="$(backends_now)"
  [ -n "${baseline}" ] && break
  sleep 5
done
[ -n "${baseline}" ] || fail "Prometheus belum punya sampel cnpg_backends_total setelah 2 menit"
echo "Baseline: ${baseline} koneksi"

log "Membuka ${TARGET_CONNECTIONS} koneksi ke Postgres lewat Job"
kc delete job cnpg-connection-drill -n "${APP_NAMESPACE}" --ignore-not-found >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: cnpg-connection-drill
  namespace: ${APP_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        postgres-client: "true"
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: drill
        image: ${PROBE_IMAGE}
        imagePullPolicy: IfNotPresent
        env:
        - name: PGHOST
          valueFrom: { secretKeyRef: { name: postgres-app, key: host } }
        - name: PGPORT
          valueFrom: { secretKeyRef: { name: postgres-app, key: port } }
        - name: PGDATABASE
          valueFrom: { secretKeyRef: { name: postgres-app, key: dbname } }
        - name: PGUSER
          valueFrom: { secretKeyRef: { name: postgres-app, key: username } }
        - name: PGPASSWORD
          valueFrom: { secretKeyRef: { name: postgres-app, key: password } }
        command: ["/bin/bash", "-c"]
        args:
        - |
          for i in \$(seq 1 ${TARGET_CONNECTIONS}); do
            psql -c "select pg_sleep(600)" &
          done
          wait
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
EOF

log "Menunggu cnpg_backends_total naik ke atas ${SUCCESS_THRESHOLD}"
observed=""
rise_deadline=$(( SECONDS + 120 ))
while [ "${SECONDS}" -lt "${rise_deadline}" ]; do
  observed="$(backends_now)"
  observed="${observed%.*}"
  if [[ "${observed}" =~ ^[0-9]+$ ]] && [ "${observed}" -ge "${SUCCESS_THRESHOLD}" ]; then
    break
  fi
  sleep 5
done

if [[ "${observed}" =~ ^[0-9]+$ ]] && [ "${observed}" -ge "${SUCCESS_THRESHOLD}" ]; then
  echo "cnpg_backends_total naik dari ${baseline} ke ${observed} (ambang ${SUCCESS_THRESHOLD}), terbukti."
else
  fail "cnpg_backends_total cuma mencapai ${observed:-0} (baseline ${baseline}), tidak melewati ambang ${SUCCESS_THRESHOLD} setelah 2 menit"
fi
