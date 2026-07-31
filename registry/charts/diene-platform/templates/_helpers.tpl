{{/* Explicit platform name (S16). Must equal the release namespace so a
     platform physically cannot compile another platform's control plane. */}}
{{- define "diene-platform.platform" -}}
{{- $platform := required "platform is required (services.yaml top-level, explicit — S16)" .Values.platform -}}
{{- if ne $platform .Release.Namespace -}}
{{- fail (printf "platform %q must equal release namespace %q" $platform .Release.Namespace) -}}
{{- end -}}
{{- $platform -}}
{{- end -}}

{{/* The one configurable label/annotation prefix. */}}
{{- define "diene-platform.labelPrefix" -}}
{{- required "labelPrefix is required" .Values.labelPrefix | trimSuffix "/" -}}
{{- end -}}

{{/* Control-plane object labels; platform key uses labelPrefix. */}}
{{- define "diene-platform.labels" -}}
{{- $prefix := include "diene-platform.labelPrefix" . -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: diene-fleet
{{ printf "%s/platform" $prefix }}: {{ include "diene-platform.platform" . | quote }}
{{- end -}}

{{/* A per-service Kargo stage name: <platform>-<service>-<landscape>. */}}
{{- define "diene-platform.stageName" -}}
{{- printf "%s-%s-%s" .platform .service .landscape -}}
{{- end -}}

{{/* Normalize a single pipeline step into a JSON array of landscape objects
     {landscape, gate, soak, verification}. A step is a bare landscape name, an
     object, or a list of either (a [parallel, set] step). */}}
{{- define "diene-platform.stepLandscapes" -}}
{{- $step := . -}}
{{- $out := list -}}
{{- $defaults := dict "gate" "auto" "soak" "" -}}
{{- if kindIs "string" $step -}}
{{- $out = append $out (dict "landscape" $step "gate" "auto" "soak" "") -}}
{{- else if kindIs "map" $step -}}
{{- $out = append $out (mergeOverwrite (deepCopy $defaults) (deepCopy $step)) -}}
{{- else if kindIs "slice" $step -}}
{{- range $member := $step -}}
{{- if kindIs "string" $member -}}
{{- $out = append $out (dict "landscape" $member "gate" "auto" "soak" "") -}}
{{- else -}}
{{- $out = append $out (mergeOverwrite (deepCopy $defaults) (deepCopy $member)) -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- fail (printf "pipeline step %v has an unsupported shape" $step) -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/* Classify a dependency module for delivery-mode rendering. Returns the
     rail: "replicated" (g2 every-cluster), "external" (Primordial, no rail),
     or "local" (recognized so the compiler can reject this Garden-owned rail
     before any Primordial object is rendered). */}}
{{- define "diene-platform.deliveryRail" -}}
{{- $delivery := required "dependency module requires an explicit delivery" .delivery -}}
{{- if not (has $delivery (list "external" "local" "replicated")) -}}
{{- fail (printf "delivery %q must be external|local|replicated" $delivery) -}}
{{- end -}}
{{- $delivery -}}
{{- end -}}
