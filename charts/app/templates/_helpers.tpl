{{/*
Nama objek utama rilis: Deployment, Service, dan HorizontalPodAutoscaler.
*/}}
{{- define "app.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Label baku yang ditempelkan ke metadata objek. Menelusuri objek kembali ke rilis
dan chart yang membuatnya.

Sengaja tidak dipakai di label Pod maupun di selector. Nilai helm.sh/chart
berubah setiap versi chart naik, sehingga menaruhnya di template Pod akan memicu
rollout hanya karena penomoran chart berubah — bukan karena aplikasinya berubah.
*/}}
{{- define "app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Label identitas Pod aplikasi, dipakai sebagai selector Deployment, selector
Service, dan sasaran NetworkPolicy. Nilainya tetap: mengubah selector Deployment
tidak diizinkan setelah objeknya dibuat, jadi ini bukan sesuatu yang layak
dijadikan parameter.
*/}}
{{- define "app.selectorLabels" -}}
app: project-management
{{- end }}

{{/*
Menandai Pod sebagai klien database. Terpisah dari label identitas di atas supaya
Pod Job bisa mendapat izin ke PostgreSQL tanpa ikut terseleksi Service aplikasi —
kalau labelnya disamakan, trafik dari Gateway sesekali mendarat di Pod Job.
*/}}
{{- define "app.databaseClientLabel" -}}
{{ .Values.databaseClientLabel.key }}: {{ .Values.databaseClientLabel.value | quote }}
{{- end }}

{{/*
Variabel lingkungan yang menunjuk ke URL koneksi database.
*/}}
{{- define "app.databaseUrlEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.database.name }}
      key: {{ .Values.secrets.database.key }}
{{- end }}

{{/*
securityContext tingkat Pod. Sama untuk aplikasi maupun Job: UID disebut angka
karena image memakai nama user, dan kubelet tidak bisa memastikan nama itu bukan
root tanpa menjalankan containernya lebih dulu.
*/}}
{{- define "app.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
securityContext tingkat container.
*/}}
{{- define "app.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
