{{- define "relay.env" -}}
- name: DATABASE_URL
  value: {{ required "database.url is required" .Values.database.url | quote }}
- name: DATABASE_PASSWORD_FILE
  value: /run/secrets/relay/database-password
- name: POOL_SIZE
  value: {{ .Values.database.poolSize | quote }}
- name: RELAY_HOST
  value: {{ .Values.host | quote }}
- name: PORT
  value: "4000"
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretKeyBaseSecret }}
      key: secret-key-base
{{- end -}}

{{- define "relay.image" -}}
{{ .Values.image.repository }}@{{ required "image.digest is required" .Values.image.digest }}
{{- end -}}
