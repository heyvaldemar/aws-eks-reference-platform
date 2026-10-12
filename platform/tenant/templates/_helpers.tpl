{{/*
The tenant's name, after the checks that keep it from taking a platform
name: a DNS label, not reserved, not kube-* or tenant-*.
*/}}
{{- define "tenant.name" -}}
{{- $n := required "name: the tenant's directory name under apps/" .Values.name -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$" $n) -}}
{{- fail (printf "apps/%s: a tenant name is a DNS label: lowercase letters, digits and hyphens" $n) -}}
{{- end -}}
{{- if or (hasPrefix "kube-" $n) (hasPrefix "tenant-" $n) (has $n .Values.reserved) -}}
{{- fail (printf "apps/%s: %s is a platform name; a tenant cannot take it" $n $n) -}}
{{- end -}}
{{- $n -}}
{{- end -}}
