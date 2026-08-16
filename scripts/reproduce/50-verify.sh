#!/usr/bin/env bash
# Memeriksa Definition of Done Fase 2 sebagai pemeriksaan yang bisa gagal,
# bukan sebagai pengamatan manual. Seluruh pemeriksaan dijalankan sampai habis
# walau ada yang gagal, supaya satu kali jalan memberi gambaran penuh.
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

# Menjalankan Pod yang mencoba membuka satu koneksi TCP, lalu menyimpulkan dari
# isi lognya. Keputusan sengaja tidak diambil dari sukses atau gagalnya Job: Job
# yang gagal karena sebab lain — image tidak ada, Pod ditolak Pod Security, salah
# argumen — tidak boleh terbaca sebagai bukti bahwa policy tidak menegakkan apa
# pun.
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
    *REACHABLE*) bad "${label} — koneksi justru BERHASIL, policy tidak tertegakkan" ;;
    *)           bad "${label} — probe tidak melaporkan hasil (phase ${phase:-tidak diketahui}), kemungkinan probe-nya sendiri gagal jalan. Log: ${probe_log}" ;;
  esac
  kc delete job "${name}" -n "${ns}" --ignore-not-found >/dev/null
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
check_eq "HTTP /auth/signin lewat Gateway" "200" "$(gateway_http_code /auth/signin)"

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

# Pembuktian langsung bahwa aturan masuk benar-benar memblokir, bukan sekadar ada.
#
# Pod uji sengaja dijalankan dari namespace lain. Aturan masuk Postgres hanya
# mengizinkan Pod ber-label `postgres-client` di namespace yang sama, jadi Pod
# dari luar pasti ditolak olehnya. Menjalankannya dari namespace aplikasi tidak
# lagi membuktikan hal itu sejak egress dibatasi: Pod tanpa label akan terhenti
# di aturan keluar lebih dulu, sehingga hasilnya tidak bisa dikaitkan ke aturan
# masuk yang sedang diuji.
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

# Pasangan dari pemeriksaan 7, arah sebaliknya.
#
# Pasangan pemeriksaan 7 dari dalam namespace aplikasi: Pod yang tidak membawa
# penanda klien tidak boleh bisa menjangkau database.
#
# Judulnya sengaja tidak menyebut aturan mana yang bekerja. Pod ini ditolak oleh
# aturan masuk maupun aturan keluar sekaligus, dan hasil "terblokir" tidak bisa
# dikaitkan ke salah satunya saja. Yang dijamin pemeriksaan ini adalah postur
# akhirnya, dan itu yang berlaku secara operasional.
#
# Menguji aturan keluar secara terpisah butuh tujuan yang aturan masuknya terbuka,
# dan tidak ada Pod semacam itu di namespace ini. Tujuan di luar namespace sudah
# dicoba dan ternyata tidak ditegakkan sama sekali oleh CNI di lingkungan ini,
# sehingga tidak bisa dipakai sebagai pembuktian.
log "10. Pod tanpa penanda klien tidak bisa menjangkau database"
netpol_probe "${APP_NAMESPACE}" netpol-egress-probe \
  "postgres-rw.${APP_NAMESPACE}.svc.cluster.local" 5432 \
  "koneksi ke database dari Pod tanpa penanda klien diblokir"

log "Ringkasan"
if [ "${FAILED}" -eq 0 ]; then
  echo "Seluruh pemeriksaan cepat lolos."
  echo "Uji restore belum termasuk di sini — jalankan 60-restore-drill.sh."
else
  echo "${FAILED} pemeriksaan gagal."
  exit 1
fi
