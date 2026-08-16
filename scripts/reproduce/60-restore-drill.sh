#!/usr/bin/env bash
# Membuktikan backup benar-benar bisa dipulihkan: membuat Cluster baru dari
# backup, membandingkan jumlah baris dengan sumbernya, lalu menghapusnya lagi.
#
# Dipisah dari 50-verify.sh karena durasinya jauh berbeda — pemeriksaan di sana
# selesai dalam hitungan detik, sedangkan pemulihan di sini menunggu Cluster baru
# dibangun. Menggabungkan keduanya membuat pemeriksaan cepat ikut tersandera dan
# praktis tidak pernah dijalankan.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
require_cluster

DRILL_CLUSTER=postgres-restore-test

# Pembersihan dijalankan di awal (supaya sisa jalan sebelumnya tidak terbaca
# sebagai hasil) dan di akhir HANYA kalau uji lolos. Sengaja tidak dipasang
# sebagai trap EXIT: interupsi dan kegagalan akan ikut memicunya, sehingga
# Cluster yang macet terhapus berikut satu-satunya bukti penyebabnya.
cleanup() {
  kc delete cluster "${DRILL_CLUSTER}" -n "${APP_NAMESPACE}" --ignore-not-found >/dev/null
}

log "Membersihkan sisa uji sebelumnya"
cleanup

# Acuan pembanding diambil sebelum Cluster restore dibuat, lalu dipakai apa
# adanya. Membaca ulang sumber setelah pemulihan selesai membuat perbandingan
# ikut bergerak kalau sumbernya berubah di tengah jalan, sehingga restore yang
# benar bisa dilaporkan gagal.
#
# Pembandingan ini mengandaikan sumber tidak ditulisi selama uji berjalan.
log "Mencatat acuan dari cluster sumber"
declare -A EXPECTED
for table in Project Category User; do
  EXPECTED["${table}"]="$(psql_count postgres "${table}")"
  printf '  %s: %s\n' "${table}" "${EXPECTED[${table}]}"
done

log "Membuat Cluster dari backup"
kc apply -f "${REPO_ROOT}/k8s/app/cluster-restore.yaml" >/dev/null

if wait_cluster_ready "${DRILL_CLUSTER}"; then
  log "Membandingkan isi dengan acuan"
  for table in Project Category User; do
    expected="${EXPECTED[${table}]}"
    actual="$(psql_count "${DRILL_CLUSTER}" "${table}")"
    if [ "${expected}" = "${actual}" ]; then
      pass "${table} (${actual})"
    else
      bad "${table} — acuan ${expected}, hasil restore ${actual}"
    fi
  done
else
  bad "Cluster hasil restore tidak pernah Ready"
fi

log "Ringkasan"
if [ "${FAILED}" -eq 0 ]; then
  cleanup
  echo "Uji restore lolos."
else
  echo "${FAILED} pemeriksaan gagal."
  echo "Cluster ${DRILL_CLUSTER} sengaja dibiarkan hidup untuk diperiksa."
  echo "Hapus manual kalau sudah selesai:"
  echo "  kubectl delete cluster ${DRILL_CLUSTER} -n ${APP_NAMESPACE}"
  exit 1
fi
