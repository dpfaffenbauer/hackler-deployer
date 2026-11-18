{{- define "hackler.tag" -}}{{ .tag | default .root.Chart.AppVersion }}{{- end -}}

{{- define "hackler.operatorImage" -}}
{{ .Values.image.repository }}:{{ include "hackler.tag" (dict "tag" .Values.image.tag "root" .) }}
{{- end -}}

{{- define "hackler.machineImage" -}}
{{ .Values.machineImage.repository }}:{{ include "hackler.tag" (dict "tag" .Values.machineImage.tag "root" .) }}
{{- end -}}

{{- define "hackler.labels" -}}
app.kubernetes.io/name: hackler-operator
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
