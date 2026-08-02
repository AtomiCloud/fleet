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

{{/* Fail-closed guard over the pipeline DAG's step/landscape contract. Emits
     nothing; it exists only to refuse an input the renderer would otherwise
     accept and then quietly mis-compile.

     (1) UNIQUE LANDSCAPES ACROSS THE WHOLE DAG. `diene-platform.stageName`
         derives a Stage name from platform+service+landscape ALONE, so a
         landscape repeated in two steps renders two Kargo Stage objects with
         the SAME name in one namespace. JSON Schema cannot express this: its
         `uniqueItems` compares whole member VALUES inside a SINGLE step, so
         "pichu" and {landscape: pichu} are distinct items to it, and it cannot
         see across steps at all. The invariant therefore lives here, where the
         flattening the renderer actually performs is available.

     (2) NO SOAK ON THE FIRST STEP. The first step subscribes DIRECTLY to the
         Warehouse, so it has no upstream Stage to occupy; Kargo's
         sources.requiredSoakTime has nothing to measure. Rendering it would
         silently drop the declared soak (and, worse, still stamp the soak
         annotation), so declaring one is refused rather than ignored. */}}
{{- define "diene-platform.assertPipeline" -}}
{{- $seen := dict -}}
{{- range $i, $step := .Values.stages -}}
{{- range $ls := include "diene-platform.stepLandscapes" $step | fromJsonArray -}}
{{- if hasKey $seen $ls.landscape -}}
{{- fail (printf "pipeline landscape %q is declared more than once (step %d and step %d); a Kargo Stage name is <platform>-<service>-<landscape>, so a repeat renders two Stages with the SAME name in one namespace" $ls.landscape (index $seen $ls.landscape) (add1 $i)) -}}
{{- end -}}
{{- $_ := set $seen $ls.landscape (add1 $i) -}}
{{- if and (eq $i 0) $ls.soak -}}
{{- fail (printf "pipeline step 1 declares soak %q on landscape %q, but the first step subscribes DIRECTLY to the Warehouse and has no upstream Stage to soak in; Kargo's requiredSoakTime would be silently dropped — remove the soak or place this landscape after another step" $ls.soak $ls.landscape) -}}
{{- end -}}
{{- end -}}
{{- end -}}
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
