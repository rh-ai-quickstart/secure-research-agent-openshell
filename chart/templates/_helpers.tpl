{{- define "secure-research-agent.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "secure-research-agent.labels" -}}
app.kubernetes.io/name: {{ include "secure-research-agent.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
