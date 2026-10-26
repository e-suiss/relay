{{- define "relay.env" -}}
- name: DATABASE_URL
  value: {{ required "database.url is required" .Values.database.url | quote }}
- name: DATABASE_PASSWORD_FILE
  value: /run/secrets/relay/database-password
{{ include "relay.env.shared" . }}
{{- end -}}

{{- define "relay.env.shared" -}}
- name: QUEUE_DATABASE_URL
  value: {{ required "database.queueUrl is required" .Values.database.queueUrl | quote }}
- name: QUEUE_DATABASE_PASSWORD_FILE
  value: /run/secrets/relay/queue-database-password
- name: MAINT_DATABASE_URL
  value: {{ required "database.maintUrl is required" .Values.database.maintUrl | quote }}
- name: MAINT_DATABASE_PASSWORD_FILE
  value: /run/secrets/relay/maint-database-password
- name: POOL_SIZE
  value: {{ .Values.database.poolSize | quote }}
- name: VALKEY_URL
  value: {{ required "valkey.url is required" .Values.valkey.url | quote }}
- name: RELAY_HOST
  value: {{ .Values.host | quote }}
- name: PORT
  value: "4000"
- name: METRICS_PORT
  value: {{ required "metrics.port is required" .Values.metrics.port | quote }}
- name: PKCS11_MODULE
  value: {{ required "keyStore.module is required" .Values.keyStore.module | quote }}
- name: PKCS11_TOKEN
  value: {{ required "keyStore.token is required" .Values.keyStore.token | quote }}
- name: PKCS11_PIN_FILE
  value: /run/secrets/relay-pkcs11/pin
- name: KEY_STORE_KEK_LABEL
  value: {{ required "keyStore.kekLabel is required" .Values.keyStore.kekLabel | quote }}
- name: KEY_STORE_FINGERPRINT_LABEL
  value: {{ required "keyStore.fingerprintLabel is required" .Values.keyStore.fingerprintLabel | quote }}
- name: AUDIT_S3_ENDPOINT
  value: {{ required "auditStore.endpoint is required" .Values.auditStore.endpoint | quote }}
- name: AUDIT_S3_BUCKET
  value: {{ required "auditStore.bucket is required" .Values.auditStore.bucket | quote }}
- name: AUDIT_S3_REGION
  value: {{ required "auditStore.region is required" .Values.auditStore.region | quote }}
- name: AUDIT_S3_ACCESS_KEY_ID
  value: {{ required "auditStore.accessKeyId is required" .Values.auditStore.accessKeyId | quote }}
- name: AUDIT_S3_SECRET_ACCESS_KEY_FILE
  value: /run/secrets/relay-audit-store/secret-access-key
- name: SECRET_KEY_BASE_FILE
  value: /run/secrets/relay-secret-key-base/secret-key-base
{{- with .Values.keyStore.env }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "relay.image" -}}
{{ .Values.image.repository }}@{{ required "image.digest is required" .Values.image.digest }}
{{- end -}}

{{- define "relay.bootstrap-container" -}}
- name: {{ .name }}
  image: {{ include "relay.image" .root }}
  args: ["eval", "Relay.Release.bootstrap()"]
  env:
    {{- include "relay.env" .root | nindent 4 }}
    - name: RELAY_ROLES
      value: worker
    - name: ADMIN_DATABASE_URL
      value: {{ required "database.adminUrl is required" .root.Values.database.adminUrl | quote }}
    - name: ADMIN_DATABASE_PASSWORD_FILE
      value: /run/secrets/relay-admin/password
  volumeMounts:
    - name: database-password
      mountPath: /run/secrets/relay
      readOnly: true
    - name: admin-password
      mountPath: /run/secrets/relay-admin
      readOnly: true
    - name: audit-store-secret
      mountPath: /run/secrets/relay-audit-store
      readOnly: true
    - name: secret-key-base
      mountPath: /run/secrets/relay-secret-key-base
      readOnly: true
{{- end -}}

{{- define "relay.secret-key-base-volume" -}}
- name: secret-key-base
  secret:
    secretName: {{ .Values.secretKeyBaseSecret }}
    items:
      - key: secret-key-base
        path: secret-key-base
{{- end -}}
