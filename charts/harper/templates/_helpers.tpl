{{/* ===================================================================== */}}
{{/* Naming helpers                                                        */}}
{{/* ===================================================================== */}}

{{- define "harper.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "harper.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "harper.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "harper.labels" -}}
helm.sh/chart: {{ include "harper.chart" . }}
{{ include "harper.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: harper
{{- end -}}

{{- define "harper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "harper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "harper.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "harper.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Headless service name — used for stable per-pod DNS. */}}
{{- define "harper.headlessServiceName" -}}
{{- printf "%s-headless" (include "harper.fullname" .) -}}
{{- end -}}

{{/* Full image reference (digest takes precedence over tag). */}}
{{- define "harper.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/* Admin secret name. */}}
{{- define "harper.adminSecretName" -}}
{{- if .Values.harper.admin.existingSecret -}}
{{- .Values.harper.admin.existingSecret -}}
{{- else -}}
{{- printf "%s-admin" (include "harper.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Resolve whether replication should be active. */}}
{{- define "harper.replicationEnabled" -}}
{{- $r := .Values.replication.enabled -}}
{{- if kindIs "bool" $r -}}
{{- $r -}}
{{- else if eq (toString $r) "auto" -}}
{{- if gt (int .Values.replicaCount) 1 -}}true{{- else -}}false{{- end -}}
{{- else -}}
{{- $r -}}
{{- end -}}
{{- end -}}

{{/* Cluster domain (overridable via .Values.clusterDomain). */}}
{{- define "harper.clusterDomain" -}}
{{- default "cluster.local" .Values.clusterDomain -}}
{{- end -}}
