#!/usr/bin/env bash
#
# cycle.sh — scripted teardown/rebuild of the disposable layers.
#
# This is the C-02 test harness. The claim under test: "the cluster can be
# destroyed between sessions and rebuilt from platform-bootstrap + Argo sync
# without manual steps." The data the claims register asks for is wall-clock
# minutes down and up, and the number of manual interventions (target: zero).
# Both fall out of running this and reading cycle-results.tsv.
#
# The boundary this script enforces in code, not prose: it will only ever
# touch 2-cluster and 3-argocd. 0-foundation and 1-network are the layers
# that persist — identity and reachability outlive compute — and the whole
# four-layer split exists to make that boundary real. A teardown script that
# *could* destroy the VPC would quietly undo it, so this one cannot address
# those layers at all.
#
# Manual interventions are measured, not accommodated. Every terraform call
# runs with -input=false, so anything that would have prompted a human fails
# the run instead of waiting for one. A hang is not a passing cycle; a
# failure here is the honest C-02 data point.
#
# Usage:
#   ./scripts/cycle.sh down            # destroy 3-argocd, then 2-cluster
#   ./scripts/cycle.sh up              # apply 2-cluster, then 3-argocd, verify
#   ./scripts/cycle.sh cycle [N]       # N full down+up cycles (default 1)
#   ./scripts/cycle.sh status          # what's live right now
#
# Env overrides:
#   PROJECT_ID  (default: platform-factory-ref)
#   BUCKET      (default: ${PROJECT_ID}-tfstate)
#   ARGOCD_NS   (default: argocd)
#   SYNC_TIMEOUT_SECONDS (default: 600) — how long "up" waits for the root
#                        Application to report Synced/Healthy

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYERS_DIR="${REPO_ROOT}/layers"
RESULTS_FILE="${REPO_ROOT}/scripts/cycle-results.tsv"

PROJECT_ID="${PROJECT_ID:-platform-factory-ref}"
BUCKET="${BUCKET:-${PROJECT_ID}-tfstate}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
SYNC_TIMEOUT_SECONDS="${SYNC_TIMEOUT_SECONDS:-600}"

# The only two layers this script is allowed to name. Anything else is a bug
# or a typo, and either way it must not reach terraform.
DISPOSABLE_LAYERS=("2-cluster" "3-argocd")

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Refuse any layer outside the disposable set. This is the persist/disposable
# boundary as an assertion — see the header.
assert_disposable() {
  local layer="$1"
  for allowed in "${DISPOSABLE_LAYERS[@]}"; do
    [[ "$layer" == "$allowed" ]] && return 0
  done
  die "refusing to operate on '${layer}'. This script only touches: ${DISPOSABLE_LAYERS[*]}. 0-foundation and 1-network persist by design."
}

preflight() {
  command -v terraform >/dev/null || die "terraform not found on PATH"
  command -v gcloud    >/dev/null || die "gcloud not found on PATH"
  command -v kubectl   >/dev/null || die "kubectl not found on PATH"

  # Fail fast and loudly on the expired-credential case. This build's own
  # log records that the Workspace org's reauth policy expires both the CLI
  # credential and ADC overnight, so this is the single most likely reason a
  # cycle dies — and it is itself C-01 evidence (a per-session manual cost),
  # so it should be named, not silently retried.
  if ! gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
    die "gcloud cannot reach project ${PROJECT_ID}. Run 'gcloud auth login' and 'gcloud auth application-default login', then retry. (Counts as a manual intervention for C-02.)"
  fi
}

# Results are the deliverable, so record every phase whether it passed or not.
record() {
  local cycle_n="$1" phase="$2" layer="$3" seconds="$4" exit_code="$5" note="${6:-}"
  if [[ ! -f "$RESULTS_FILE" ]]; then
    printf 'timestamp_utc\tcycle\tphase\tlayer\tseconds\texit_code\tnote\n' > "$RESULTS_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cycle_n" "$phase" "$layer" "$seconds" "$exit_code" "$note" \
    >> "$RESULTS_FILE"
}

# .terraform/ is gitignored and disposable, so re-init every time rather than
# assuming a working directory survived the last run.
init_layer() {
  local layer="$1"
  assert_disposable "$layer"
  terraform -chdir="${LAYERS_DIR}/${layer}" init -input=false -reconfigure \
    -backend-config="bucket=${BUCKET}" >/dev/null
}

run_layer() {
  local cycle_n="$1" phase="$2" layer="$3" action="$4"
  assert_disposable "$layer"

  log "${phase}: ${action} ${layer}"
  init_layer "$layer"

  local start elapsed rc=0
  start=$SECONDS
  terraform -chdir="${LAYERS_DIR}/${layer}" "$action" -input=false -auto-approve || rc=$?
  elapsed=$(( SECONDS - start ))

  record "$cycle_n" "$phase" "$layer" "$elapsed" "$rc"
  [[ $rc -eq 0 ]] || die "${action} failed on ${layer} after ${elapsed}s (exit ${rc}). This is a C-02 manual intervention — record what you had to do."
  printf '    %s %s completed in %ss\n' "$layer" "$action" "$elapsed"
}

# "Rebuilt" has to mean the platform is back, not that terraform exited 0.
# The honest finish line for C-02/C-04 is Argo CD's root Application
# reporting Synced and Healthy against platform-config.
verify_up() {
  local cycle_n="$1"
  log "verify: waiting for root Application to report Synced/Healthy"

  # Read the cluster's identity from state rather than guessing it. No
  # fallback defaults on purpose: a wrong guess here would point kubectl at
  # some other cluster and report a cheerful pass, which is worse than
  # stopping. --location (not --region) so this keeps working if the cluster
  # is ever zonal.
  local location cluster
  location="$(terraform -chdir="${LAYERS_DIR}/2-cluster" output -raw cluster_location 2>/dev/null)" \
    || die "could not read cluster_location from 2-cluster state"
  cluster="$(terraform -chdir="${LAYERS_DIR}/2-cluster" output -raw cluster_name 2>/dev/null)" \
    || die "could not read cluster_name from 2-cluster state"

  gcloud container clusters get-credentials "$cluster" \
    --location "$location" --project "$PROJECT_ID" >/dev/null 2>&1 \
    || die "could not fetch cluster credentials for ${cluster} in ${location}"

  local start elapsed sync health
  start=$SECONDS
  while true; do
    sync="$(kubectl get application root -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")"
    health="$(kubectl get application root -n "$ARGOCD_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")"
    elapsed=$(( SECONDS - start ))

    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      record "$cycle_n" "up" "verify" "$elapsed" 0 "root Application Synced/Healthy"
      printf '    root Application Synced/Healthy after %ss\n' "$elapsed"
      return 0
    fi

    if (( elapsed > SYNC_TIMEOUT_SECONDS )); then
      record "$cycle_n" "up" "verify" "$elapsed" 1 "timeout; sync=${sync:-<none>} health=${health:-<none>}"
      warn "root Application did not reach Synced/Healthy within ${SYNC_TIMEOUT_SECONDS}s"
      warn "last seen: sync=${sync:-<none>} health=${health:-<none>}"
      # Not a hard failure: with root_app_automated_sync = false (the current
      # default) the root Application will sit OutOfSync until a human syncs
      # it, which is precisely a C-02 manual intervention worth recording
      # rather than hiding behind a longer timeout.
      die "root Application never reached Synced/Healthy — see note above. If root_app_automated_sync is false, this is expected and is the finding."
    fi
    sleep 10
  done
}

do_down() {
  local cycle_n="${1:-0}"
  log "DOWN — destroying disposable layers in reverse order"
  local start
  start=$SECONDS
  run_layer "$cycle_n" "down" "3-argocd" "destroy"
  run_layer "$cycle_n" "down" "2-cluster" "destroy"
  record "$cycle_n" "down" "TOTAL" "$(( SECONDS - start ))" 0
  log "DOWN complete in $(( (SECONDS - start) / 60 ))m $(( (SECONDS - start) % 60 ))s"
}

do_up() {
  local cycle_n="${1:-0}"
  log "UP — rebuilding disposable layers"
  local start
  start=$SECONDS
  run_layer "$cycle_n" "up" "2-cluster" "apply"
  run_layer "$cycle_n" "up" "3-argocd" "apply"
  verify_up "$cycle_n"
  record "$cycle_n" "up" "TOTAL" "$(( SECONDS - start ))" 0
  log "UP complete in $(( (SECONDS - start) / 60 ))m $(( (SECONDS - start) % 60 ))s"
}

do_status() {
  log "Live state"
  gcloud container clusters list --project "$PROJECT_ID" 2>/dev/null \
    || warn "could not list clusters"
  printf '\n'
  if kubectl get application root -n "$ARGOCD_NS" >/dev/null 2>&1; then
    kubectl get application -n "$ARGOCD_NS"
  else
    warn "no root Application reachable (cluster down, or credentials not fetched)"
  fi
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    down)
      preflight; do_down 1 ;;
    up)
      preflight; do_up 1 ;;
    cycle)
      preflight
      local n="${2:-1}"
      [[ "$n" =~ ^[0-9]+$ ]] || die "cycle count must be a number, got '${n}'"
      for (( i = 1; i <= n; i++ )); do
        log "======== CYCLE ${i} of ${n} ========"
        do_down "$i"
        do_up "$i"
      done
      log "All ${n} cycle(s) complete. Results: ${RESULTS_FILE}"
      ;;
    status)
      preflight; do_status ;;
    *)
      sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 1 ;;
  esac
}

main "$@"
