#!/usr/bin/env bash
# Memeriksa Definition of Done Fase 2 sebagai pemeriksaan yang bisa gagal,
# bukan sebagai pengamatan manual. Seluruh pemeriksaan dijalankan sampai habis
# walau ada yang gagal, supaya satu kali jalan memberi gambaran penuh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need curl
require_cluster

FAILED=0

pass() { printf '  OK    %s\n' "$*"; }
bad()  { printf '  GAGAL %s\n' "$*"; FAILED=$((FAILED + 1)); }

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass "${label} (${actual})"
  else
    bad "${label} — diharapkan '${expected}', dapat '${actual}'"
  fi
}

psql_count() {
  local cluster="$1" table="$2" primary
  primary="$(kc get cluster "${cluster}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.currentPrimary}')"
  kc exec -n "${APP_NAMESPACE}" "${primary}" -c postgres -- \
    psql -U postgres -d mydb -tAc "SELECT count(*) FROM \"${table}\""
}

log "1. Seluruh Pod berjalan dan siap"
for ns in "${APP_NAMESPACE}" "${GARAGE_NAMESPACE}"; do
  # Jumlahnya diperiksa lebih dulu: daftar Pod bermasalah yang kosong juga
  # dihasilkan oleh namespace yang sama sekali tidak berisi Pod.
  total="$(kc get pods -n "${ns}" --no-headers 2>/dev/null | wc -l)"
  if [ "${total}" -eq 0 ]; then
    bad "namespace ${ns} — tidak ada Pod sama sekali"
    continue
  fi
  # `Running` belum berarti siap melayani; yang diperiksa condition Ready.
  # Pod Job yang sudah selesai berstatus Succeeded dengan Ready=False — itu
  # keadaan normal, bukan tidak sehat.
  unhealthy="$(kc get pods -n "${ns}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2 != "Succeeded" && $3 != "True" { printf "%s(%s) ", $1, $2 }')"
  if [ -z "${unhealthy}" ]; then
    pass "namespace ${ns} (${total} Pod)"
  else
    bad "namespace ${ns} — Pod belum siap: ${unhealthy}"
  fi
done

log "2. Pod Security restricted ditegakkan"
for ns in "${APP_NAMESPACE}" "${GARAGE_NAMESPACE}"; do
  actual="$(kc get ns "${ns}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
  check_eq "enforce di namespace ${ns}" "restricted" "${actual}"
done

log "3. Aplikasi dapat dijangkau lewat Gateway"
gw_addr="$(kc get gateway project-management -n "${APP_NAMESPACE}" -o jsonpath='{.status.addresses[0].value}')"
if [ -z "${gw_addr}" ]; then
  bad "Gateway belum punya alamat"
else
  code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 60 "http://${gw_addr}/auth/signin" || echo "gagal")"
  check_eq "HTTP ${gw_addr}/auth/signin" "200" "${code}"
fi

log "4. metrics-server mengeluarkan angka"
if kc top pods -n "${APP_NAMESPACE}" >/dev/null 2>&1; then
  pass "kubectl top pods"
else
  bad "kubectl top pods tidak mengeluarkan metrik"
fi

log "5. HPA membaca metrik"
# Di-poll, bukan dibaca sekali: controller HPA baru mengisi status setelah
# sempat mengambil sampel, sehingga pembacaan tepat setelah HPA dibuat selalu
# kosong tanpa ada yang salah.
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
  bad "HPA tidak punya metrik setelah 3 menit — cek metrics-server"
fi

log "6. Data hasil seed"
check_eq "jumlah Project" "30" "$(psql_count postgres Project)"
check_eq "jumlah Category" "5" "$(psql_count postgres Category)"
check_eq "jumlah User" "1" "$(psql_count postgres User)"

# Pembuktian langsung bahwa policy benar-benar memblokir, bukan sekadar ada.
# Pod ini tidak memakai label `postgres-client`, jadi seharusnya tidak bisa
# membuka koneksi ke Postgres.
log "7. NetworkPolicy benar-benar memblokir akses tanpa label"
kc delete job netpol-probe -n "${APP_NAMESPACE}" --ignore-not-found >/dev/null
kc apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: netpol-probe
  namespace: project-management
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
        image: ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie
        imagePullPolicy: IfNotPresent
        command: ["/bin/bash", "-c"]
        args:
        - |
          if timeout 10 bash -c 'cat < /dev/null > /dev/tcp/postgres-rw/5432'; then
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
# Keputusan diambil dari isi log, bukan dari sukses/gagalnya Job. Job yang gagal
# karena sebab lain (image, penolakan Pod Security, salah argumen) tidak boleh
# terbaca sebagai bukti bahwa policy tidak menegakkan apa pun.
probe_deadline=$(( SECONDS + 120 ))
probe_phase=""
while [ "${SECONDS}" -lt "${probe_deadline}" ]; do
  probe_phase="$(kc get pods -n "${APP_NAMESPACE}" -l batch.kubernetes.io/job-name=netpol-probe \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  case "${probe_phase}" in Succeeded|Failed) break ;; esac
  sleep 5
done
probe_log="$(kc logs -n "${APP_NAMESPACE}" job/netpol-probe --tail=20 2>/dev/null || true)"
case "${probe_log}" in
  *BLOCKED*)
    pass "koneksi tanpa label postgres-client diblokir" ;;
  *REACHABLE*)
    bad "koneksi tanpa label postgres-client BERHASIL — NetworkPolicy tidak tertegakkan" ;;
  *)
    bad "probe tidak melaporkan hasil (phase ${probe_phase:-tidak diketahui}) — kemungkinan probe-nya sendiri gagal jalan, bukan soal policy. Log: ${probe_log}" ;;
esac
kc delete job netpol-probe -n "${APP_NAMESPACE}" --ignore-not-found >/dev/null

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

log "Ringkasan"
if [ "${FAILED}" -eq 0 ]; then
  echo "Seluruh pemeriksaan cepat lolos."
  echo "Uji restore belum termasuk di sini — jalankan 60-restore-drill.sh."
else
  echo "${FAILED} pemeriksaan gagal."
  exit 1
fi
