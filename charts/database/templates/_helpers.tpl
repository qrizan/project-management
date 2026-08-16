{{/*
Label baku yang ditempelkan ke setiap objek milik rilis ini. Dipakai untuk
menelusuri objek kembali ke rilis dan chart yang membuatnya.

Label ini hanya menempel di metadata objek, bukan di Pod PostgreSQL. CloudNativePG
tidak menurunkan label Cluster ke Pod-nya kecuali diminta lewat inheritedMetadata,
sehingga selektor yang mengandalkan label cnpg.io/cluster tidak terpengaruh.
*/}}
{{- define "database.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: database
{{- end }}
