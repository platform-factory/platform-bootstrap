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
# From M2 on, the cluster is no longer the whole story. The paved road makes
# a merged claim create something that lives in the cloud and outlives the
# cluster — a Cloud SQL instance, an Artifact Registry repository — so "down"
# no longer leaves an empty slate and "up" no longer builds onto one. ADR-0015
# settles what this script does about that, and the two additions below are
# the whole of it:
#
#   - `up` gains an adoption check. Once every Application is Healthy — and
#     also, marked partial, when the verify step times out — it asks each
#     durable resource when it was created in the cloud and sorts it into
#     adopted (older than this up), new (created by this up under a name this
#     file has never recorded), recreated (created by this up under a name it
#     has) or unknown (no readable timestamp). Only the last two mark the
#     row. Without it, a rebuild that quietly stood up a fresh, empty
#     database would pass the Healthy check and be recorded as a successful
#     cycle — a false C-07(c) result dressed as a green run. The results file
#     is its own prior because a timestamp alone cannot separate "failed to
#     adopt" from "this had never existed"; see EXPECT_FRESH below for the
#     one case the file cannot infer.
#   - `park` is a new, separate command that stops those instances to save
#     money between sessions. It is deliberately NOT part of `down`: C-02
#     measures rebuild time, and folding cost hygiene into the measured path
#     would change the number and hide the choice.
#
# `down` itself is unchanged and must stay that way. It could not delete a
# durable resource today even if asked (a cluster destroy is not a Kubernetes
# delete), and teaching it to would turn an evening teardown into a delete
# storm. Deleting a database for real is a human act with a runbook.
#
# Usage:
#   ./scripts/cycle.sh down            # destroy 3-argocd, then 2-cluster
#   ./scripts/cycle.sh up              # apply 2-cluster, then 3-argocd, verify
#   ./scripts/cycle.sh cycle [N]       # N full down+up cycles (default 1)
#   ./scripts/cycle.sh park            # stop every paved-road Cloud SQL
#                                      # instance (activation policy NEVER)
#   ./scripts/cycle.sh status          # what's live right now
#
# `park` may be run at any time, including while the cluster is up — it just
# will not stick. The Database Composition declares activationPolicy: ALWAYS
# and holds the Update management policy, so Crossplane treats a parked
# instance as drift and starts it again within a reconcile interval. Park
# after `down`, which is the rhythm it is for. Nothing unparks on `up`: that
# same drift correction is what brings the instance back.
#
# Cycle numbers are read from cycle-results.tsv, never typed: `down` starts
# cycle (last + 1), `up` continues the last cycle if it has a down but no up
# yet (a teardown one evening and a rebuild the next morning are one cycle),
# and `cycle N` numbers each pass consecutively from there. Before this, the
# standalone commands hard-coded cycle 1, so a second teardown was recorded
# under the same label as the first — three cycles would have read as one.
# `park` records against the cycle most recently opened rather than claiming
# a number of its own: it is an operator action between cycles, not a phase
# of one, and a new number would inflate the cycle count C-02 reports.
#
# Env overrides:
#   PROJECT_ID  (default: platform-factory-ref)
#   BUCKET      (default: ${PROJECT_ID}-tfstate)
#   ARGOCD_NS   (default: argocd)
#   REGION      (default: us-central1) — where the paved road's Artifact
#                        Registry repositories live; only the adoption check
#                        reads it.
#   SYSTEM_LABEL (default: system) — the cloud-side label key every paved-road
#                        resource carries, whose value is the System's name
#                        (ADR-0012 §1: "the labels say system=<system>").
#                        Deliberately NOT the Kubernetes spine key
#                        platform.thecloudgeek.io/system: GCP resource label
#                        keys may contain only lowercase letters, numbers,
#                        underscores and dashes, so a dotted, slashed key is
#                        rejected outright [verified 2026-09-16 against
#                        Google's "Requirements for labels", cloud.google.com
#                        /compute/docs/labeling-resources]. This is the
#                        contract with the Compositions in platform-config: if
#                        they stop labelling, park stops finding and the
#                        adoption check goes quiet rather than loud, so the
#                        key is named here once and read by both callers.
#   SYNC_TIMEOUT_SECONDS (default: 2400) — how long "up" waits for every
#                        Argo CD Application to report Synced/Healthy. This
#                        was 900 through M1, justified by Crossplane's
#                        provider packages and their first cold pull through
#                        the Artifact Registry remotes. From M2 the long pole
#                        is somewhere else entirely: verify_up waits for
#                        EVERY Application, which now includes the tenant
#                        Application the System Composition composes, and a
#                        `Database` claim sits inside it. The Database
#                        Composition leaves the DatabaseInstance to
#                        function-auto-ready rather than annotating it Ready
#                        early, so nothing goes Healthy until Cloud SQL
#                        itself reports Ready and the GRANT Job reaches
#                        Complete — an instance create (or a restart from
#                        parked) plus a Job, not a package pull. Google
#                        documents instance creation in minutes and it
#                        routinely passes ten. A timeout that is merely too
#                        short does not fail softly here: `cycle N` dies and
#                        the header tells the operator to count it as a C-02
#                        manual intervention, which manufactures a false
#                        failure out of a slow but correct rebuild.
#   EXPECT_FRESH (default: 0) — set to 1 when this rebuild is EXPECTED to
#                        create durable resources rather than adopt them.
#                        There is exactly one case the results file cannot
#                        infer on its own: ADR-0015 §6 requires exercising a
#                        rebuild after a deliberate delete at least once, and
#                        that run legitimately re-creates a resource this
#                        file has recorded before. With EXPECT_FRESH=1 the
#                        `up`/durable row keeps exit_code 0 and says the
#                        re-creation was expected; without it the row is red
#                        and reads as a C-07(c) failure. A tenant's FIRST
#                        provision needs no flag — a name this file has never
#                        seen is counted as `new`, not `recreated`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYERS_DIR="${REPO_ROOT}/layers"
RESULTS_FILE="${REPO_ROOT}/scripts/cycle-results.tsv"

PROJECT_ID="${PROJECT_ID:-platform-factory-ref}"
BUCKET="${BUCKET:-${PROJECT_ID}-tfstate}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
REGION="${REGION:-us-central1}"
SYSTEM_LABEL="${SYSTEM_LABEL:-system}"
SYNC_TIMEOUT_SECONDS="${SYNC_TIMEOUT_SECONDS:-2400}"
EXPECT_FRESH="${EXPECT_FRESH:-0}"

# The only two layers this script is allowed to name. Anything else is a bug
# or a typo, and either way it must not reach terraform.
#
# ADR-0015's durable work does not widen this. `park` and the adoption check
# read and patch cloud resources that CROSSPLANE created, through gcloud, and
# never open a terraform working directory at all — so the persist/disposable
# assertion below still covers every terraform call this script can make.
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

# The highest cycle number recorded so far (0 if there is no results file).
last_cycle_number() {
  [[ -f "$RESULTS_FILE" ]] || { echo 0; return; }
  awk -F'\t' 'NR > 1 && $2 ~ /^[0-9]+$/ && ($2 + 0) > max { max = $2 + 0 } END { print max + 0 }' \
    "$RESULTS_FILE"
}

next_cycle_number() {
  echo $(( $(last_cycle_number) + 1 ))
}

# An `up` belongs to the last cycle if that cycle recorded a down TOTAL but
# no up TOTAL yet — which also covers re-running `up` after a failed one,
# since a failed up never writes its TOTAL row. Anything else (first-ever
# bring-up, or an up after a completed cycle) starts a new number.
cycle_for_up() {
  local last
  last="$(last_cycle_number)"
  if (( last > 0 )); then
    local downs ups
    downs="$(awk -F'\t' -v c="$last" '($2 + 0) == c && $3 == "down" && $4 == "TOTAL" { n++ } END { print n + 0 }' "$RESULTS_FILE")"
    ups="$(awk -F'\t' -v c="$last" '($2 + 0) == c && $3 == "up" && $4 == "TOTAL" { n++ } END { print n + 0 }' "$RESULTS_FILE")"
    if (( downs > 0 && ups == 0 )); then
      echo "$last"
      return
    fi
  fi
  echo $(( last + 1 ))
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

# ---------------------------------------------------------------------------
# Durable resources — ADR-0015
#
# From M2 on, some of what the platform creates lives in the cloud and
# outlives the cluster: Cloud SQL instances and Artifact Registry
# repositories, the things that hold data and images. They are composed with
# managementPolicies minus Delete and with both deletion-protection flags, so
# neither a claim deletion nor a cluster destroy removes them. That is the
# point — and it is also why `up` needs a check `down` does not.
#
# Both lookups find their subjects by the ${SYSTEM_LABEL} label the
# Compositions stamp on every cloud resource, never by a hand-kept list. That
# is what keeps layer 0's own Artifact Registry remote repositories
# (docker-hub, ghcr-io, quay-io, ecr-public, registry-k8s-io) out of the
# answer: those are Terraform's, created before any System existed, and they
# carry no system label.
#
# Both --filter expressions are evaluated CLIENT-side, so gcloud's filter
# grammar applies rather than either API's server-side one — verified
# 2026-09-16 by reading gcloud 578.0.0: surface/sql/instances/list.py never
# passes args.filter to the API at all, and api_lib/artifacts/
# filter_rewriter.py hands an expression to the server only when it starts
# with "annotations" or "name=". `key:*` is gcloud's "this key is defined"
# test, so it matches whatever value the label carries.
# ---------------------------------------------------------------------------

# An RFC 3339 Zulu timestamp as a sortable 14-digit integer:
# 2026-09-16T12:34:56.789Z and 2026-09-16T12:34:56Z both give 20260916123456.
#
# Fractional seconds are dropped rather than compared because a plain string
# compare puts "...56Z" AFTER "...56.789Z" (Z sorts above .), which would
# read a resource created in the same second as this `up` as *older* than it
# — i.e. as adopted. That is the one direction of error that hides the bug
# this check exists to catch. Truncating makes the same-second case read as
# re-created instead, which gets looked at rather than ignored.
#
# The Z test on the first line is load-bearing, not belt-and-braces. Stripping
# from the first "." removes the fractional part AND any trailing offset in
# one go, so without it "2026-09-16T05:34:56.789-07:00" would come back as a
# perfectly valid-looking 14 digits of LOCAL time — a 7-hour skew biased
# toward reading a resource as older, i.e. adopted, which is again the error
# direction that hides the bug. Both APIs emit Zulu (sqladmin v1beta4
# documents "2012-11-15T16:19:00.094Z"; Artifact Registry's createTime is a
# protobuf Timestamp, which marshals as Zulu) — but the guard earned its keep
# on the very first M2 run (2026-09-16): `gcloud artifacts repositories list`
# carries a display transform that rewrites createTime into LOCAL time with
# NO zone suffix even under --format=value(...), so both registries came back
# as "2026-09-16T09:53:10" for a repository created at 16:53:10Z, and landed
# in `unknown`. The two list calls below now force UTC explicitly with
# .date(format=..., tz=UTC) rather than trusting what gcloud prints by
# default. Anything that still is not Zulu — an offset form, an empty value —
# comes back with a length other than 14 and the caller counts it as unknown
# rather than guessing.
ts_to_int() {
  [[ "$1" == *Z ]] || { printf ''; return 0; }
  local t="${1%%.*}"
  t="${t%Z}"
  printf '%s' "$t" | tr -dc '0-9'
}

# Has this durable resource appeared in an earlier `up`/durable row?
#
# This is what separates "the rebuild failed to adopt" from "this resource
# had never been created before". Both look identical to a timestamp compare
# — a cloud createTime newer than this `up` started — but only the first is a
# finding. The results file is the only thing that knows which is which, so
# it is the prior: first sighting of a name is `new`, a name we have recorded
# before and that came back with a fresh timestamp is `recreated`.
#
# Names are matched with the trailing "@" that record_durable_adoption always
# appends before the timestamp, so "cloudsql/svc-hello" cannot match a row
# that only ever mentioned "cloudsql/svc-hello-main".
durable_seen_before() {
  local label="$1"
  [[ -f "$RESULTS_FILE" ]] || return 1
  awk -F'\t' -v needle="${label}@" '
    NR > 1 && $3 == "up" && $4 == "durable" && index($7, needle) { found = 1 }
    END { exit found ? 0 : 1 }' "$RESULTS_FILE"
}

# The adoption check itself. Recorded as one `up`/durable row per cycle.
#
# Why it exists: a rebuild that silently created a brand-new empty database
# instead of adopting the existing one would still reach 100% Applications
# Synced/Healthy, and would be written into this file as a clean cycle. The
# cloud-side creation timestamp is the only thing that tells the two apart.
# Older than this up's start = adopted (the external-name import worked).
# Newer = re-created, which is a false C-07(c) result and the note says so.
#
# ADR-0015's Consequences say "the results file gains a column for it". This
# is a ROW, not a column, because a column means rewriting all 27 existing
# rows and every awk field index in this file ($2/$3/$4 in last_cycle_number,
# cycle_for_up and durable_seen_before) to carry the same information. §3's
# actual requirement — "records each durable resource's cloud-side creation
# timestamp, so the results file can distinguish adopted from re-created" —
# is met: every name in the note is written as <kind>/<name>@<createTime>, so
# a `recreated` row can be re-read months later without re-querying GCP. If
# the literal column is wanted it is a separate, mechanical TSV migration.
#
# Coverage is narrower than ADR-0015 §1's durable set, deliberately. §1 names
# DatabaseInstance, Database and RegistryRepository; this checks the first and
# third only. The composed sql `Database` ("app") carries no createTime at all
# — its API resource has exactly charset, collation, etag, instance, kind,
# name, project, selfLink and sqlserverDatabaseDetails [verified 2026-09-16
# against gcloud 578.0.0's sqladmin v1beta4 Database message] — so the
# timestamp technique cannot reach it. The substitute is an implication, not
# an omission: Crossplane observes a database inside an instance it did not
# re-create, so an adopted instance means its `app` database was adopted too.
#
# This must never fail a cycle. On an M1-shaped platform — no Systems yet,
# no durable resources — it finds nothing and records zeroes, which is the
# behaviour cycles 1-4 in this file were recorded under. A re-creation, an
# unreadable timestamp, or a listing failure is a loud warning and an
# exit_code of 1 on this row only, so the column stays scannable, but the
# rebuild itself still succeeded and the script still exits 0.
record_durable_adoption() {
  local cycle_n="$1" up_start_utc="$2" qualifier="${3:-}"
  local start; start=$SECONDS

  local sql_rows="" ar_rows="" list_rc=0
  sql_rows="$(gcloud sql instances list \
    --project "$PROJECT_ID" \
    --filter="settings.userLabels.${SYSTEM_LABEL}:*" \
    --format="value(name,createTime.date(format='%Y-%m-%dT%H:%M:%SZ',tz=UTC))" 2>/dev/null)" || list_rc=1

  # --location pins this to one region. Without it gcloud fans out across
  # every Artifact Registry location, which is a handful of extra API calls
  # for an answer the System Composition already constrains to ${REGION}.
  # `name` comes back as the full projects/.../repositories/<id> path, so
  # basename() is what turns it back into the repository id.
  ar_rows="$(gcloud artifacts repositories list \
    --project "$PROJECT_ID" \
    --location "$REGION" \
    --filter="labels.${SYSTEM_LABEL}:*" \
    --format="value(name.basename(),createTime.date(format='%Y-%m-%dT%H:%M:%SZ',tz=UTC))" 2>/dev/null)" || list_rc=1

  local up_int; up_int="$(ts_to_int "$up_start_utc")"

  local adopted=0 recreated=0 fresh=0 unknown=0
  local adopted_names="" recreated_names="" fresh_names="" unknown_names=""
  local kind name created created_int label stamped

  while IFS=$'\t' read -r kind name created; do
    [[ -n "$name" ]] || continue
    label="${kind}/${name}"
    created_int="$(ts_to_int "${created:-}")"
    # Every name carries its createTime so the row stays re-readable, and so
    # durable_seen_before has a stable "@" delimiter to anchor on.
    stamped="${label}@${created:-?}"
    if [[ ${#created_int} -ne 14 || ${#up_int} -ne 14 ]]; then
      unknown=$(( unknown + 1 ))
      unknown_names="${unknown_names}${unknown_names:+ }${stamped}"
    elif (( 10#$created_int < 10#$up_int )); then
      adopted=$(( adopted + 1 ))
      adopted_names="${adopted_names}${adopted_names:+ }${stamped}"
    elif durable_seen_before "$label"; then
      recreated=$(( recreated + 1 ))
      recreated_names="${recreated_names}${recreated_names:+ }${stamped}"
    else
      # Created during this up, and never recorded before: this is the
      # tenant's first provision, not a failed adoption. Counting it as
      # `recreated` would make every new System's first cycle a red row.
      fresh=$(( fresh + 1 ))
      fresh_names="${fresh_names}${fresh_names:+ }${stamped}"
    fi
  done <<< "$(
    printf '%s\n' "$sql_rows" | awk -F'\t' 'NF { printf "cloudsql\t%s\t%s\n", $1, $2 }'
    printf '%s\n' "$ar_rows"  | awk -F'\t' 'NF { printf "registry\t%s\t%s\n", $1, $2 }'
  )"

  local total=$(( adopted + recreated + fresh + unknown ))
  local note rc=0
  if (( list_rc != 0 )); then
    note="listing failed; partial result — adopted: ${adopted}, recreated: ${recreated}, new: ${fresh}, unknown: ${unknown}"
    rc=1
  elif (( total == 0 )); then
    # A cheerful zero is only honest if there is genuinely nothing to find.
    # If Systems or Database claims exist and no cloud resource carries the
    # label, the Compositions have stopped stamping it and BOTH this check
    # and `park` have silently gone blind — the exact "assumption rather than
    # evidence" ADR-0015 §3 exists to prevent. kubectl is live here: this
    # runs only after get-credentials succeeded and every Application is
    # Healthy, so asking the cluster costs nothing.
    local expected=0 claims=0 systems=0
    systems="$(kubectl get systems.platform.thecloudgeek.io --no-headers 2>/dev/null | wc -l | tr -d ' ')" || systems=0
    claims="$(kubectl get databases.platform.thecloudgeek.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')" || claims=0
    expected=$(( ${systems:-0} + ${claims:-0} ))
    if (( expected > 0 )); then
      rc=1
      note="adopted: 0, recreated: 0 but ${systems} System(s) and ${claims} Database claim(s) exist — no cloud resource carries a '${SYSTEM_LABEL}' label; the Compositions are not stamping it (System: RegistryRepository forProvider.labels.${SYSTEM_LABEL}; Database: DatabaseInstance settings.userLabels.${SYSTEM_LABEL})"
    else
      note="adopted: 0, recreated: 0 — no durable resources carry a '${SYSTEM_LABEL}' label yet"
    fi
  else
    note="adopted: ${adopted}${adopted_names:+ [${adopted_names}]}, recreated: ${recreated}${recreated_names:+ [${recreated_names}]}"
    (( fresh > 0 )) && note="${note}, new: ${fresh} [${fresh_names}]"
    (( unknown > 0 )) && note="${note}, unknown: ${unknown} [${unknown_names}]"
    if (( recreated > 0 && EXPECT_FRESH == 1 )); then
      note="${note} (expected: EXPECT_FRESH=1, post-delete rebuild per ADR-0015 §6)"
    elif (( recreated > 0 )); then
      rc=1
    fi
    # An all-unknown result is the quietest possible failure: the check ran,
    # answered nothing, and would otherwise write a green row. Mark it.
    (( unknown > 0 )) && rc=1
  fi

  [[ -n "$qualifier" ]] && note="${note} — ${qualifier}"

  record "$cycle_n" "up" "durable" "$(( SECONDS - start ))" "$rc" "$note"
  printf '    durable resources — %s\n' "$note"

  if (( list_rc != 0 )); then
    warn "could not enumerate durable resources; the adoption evidence for this cycle is incomplete"
  elif (( recreated > 0 && EXPECT_FRESH != 1 )); then
    warn "${recreated} durable resource(s) were CREATED by this rebuild, not adopted: ${recreated_names}"
    warn "C-07(c) says a rebuild adopts by external name. Check crossplane.io/external-name on the composed resource before trusting this cycle."
    warn "If this rebuild followed a deliberate delete (ADR-0015 §6), re-run with EXPECT_FRESH=1 so the row records the expectation."
  fi
  if (( unknown > 0 )); then
    warn "${unknown} durable resource(s) returned an unparseable creation timestamp: ${unknown_names}"
    warn "The adoption evidence for this cycle is incomplete — ts_to_int wants RFC 3339 Zulu; check what gcloud actually returned."
  fi
  return 0
}

# park — ADR-0015 §4. Stop every Cloud SQL instance the paved road created so
# an idle reference build is not billed for compute nobody is using. Google's
# activation policy NEVER "suspends instance charges"; storage and the
# reserved private IP keep billing, which is the honest trade against
# deleting the thing C-07(c) exists to protect.
#
# Deliberately not part of `down`: C-02's number is rebuild wall-clock, and a
# cost step inside the measured path would change that number and hide the
# choice. The known failure mode of an explicit command is that someone
# forgets to run it — accepted, because the cost of forgetting is a bill and
# the cost of the alternative is a deletion, and this file records whether it
# ran.
#
# Artifact Registry repositories are not parked. A repository has no running
# compute to stop — only storage, which is exactly what we are paying to keep.
#
# One instance failing does not abort the rest: park is cost hygiene across
# every tenant, and leaving four instances running because the fifth errored
# would be the expensive reading of "fail fast". Each failure is recorded on
# its own row and the command exits non-zero at the end.
do_park() {
  local cycle_n="$1"
  log "PARK — activation policy NEVER on every Cloud SQL instance labelled '${SYSTEM_LABEL}'"

  local total_start; total_start=$SECONDS
  local instances rc=0
  instances="$(gcloud sql instances list \
    --project "$PROJECT_ID" \
    --filter="settings.userLabels.${SYSTEM_LABEL}:*" \
    --format="value(name)")" || rc=$?

  if (( rc != 0 )); then
    record "$cycle_n" "park" "TOTAL" "$(( SECONDS - total_start ))" "$rc" "could not list Cloud SQL instances"
    die "could not list Cloud SQL instances in ${PROJECT_ID} (exit ${rc})"
  fi

  if [[ -z "${instances//[[:space:]]/}" ]]; then
    # "Nothing to park" and "the label contract broke" produce byte-identical
    # output from the filtered list, and only one of them is good news. Ask
    # again without the filter: an unlabelled instance in this project is
    # either the Compositions having stopped stamping ${SYSTEM_LABEL} — in
    # which case park has gone blind and is leaving compute billing — or
    # someone's hand-made instance, and both deserve a sentence rather than
    # silence. kubectl is not available here on purpose: park is for when the
    # cluster is down, so gcloud is the only witness.
    local all_instances="" unlabelled=0
    all_instances="$(gcloud sql instances list --project "$PROJECT_ID" \
      --format="value(name)" 2>/dev/null)" || all_instances=""
    unlabelled="$(printf '%s\n' "$all_instances" | awk 'NF' | wc -l | tr -d ' ')"

    if (( ${unlabelled:-0} > 0 )); then
      record "$cycle_n" "park" "TOTAL" "$(( SECONDS - total_start ))" 1 \
        "parked: 0 but ${unlabelled} Cloud SQL instance(s) exist with no '${SYSTEM_LABEL}' label — park found nothing to act on"
      warn "${unlabelled} Cloud SQL instance(s) in ${PROJECT_ID} carry no '${SYSTEM_LABEL}' label, so park skipped them and they are still billing."
      warn "If these are paved-road instances, the Database Composition has stopped setting settings.userLabels.${SYSTEM_LABEL} — fix that rather than parking by hand."
      log "PARK — nothing matched the label"
      return 0
    fi

    record "$cycle_n" "park" "TOTAL" "$(( SECONDS - total_start ))" 0 \
      "parked: 0 — no Cloud SQL instance carries a '${SYSTEM_LABEL}' label"
    log "PARK — nothing to park"
    return 0
  fi

  local parked=0 failed=0 name irc elapsed start note
  while read -r name; do
    [[ -n "$name" ]] || continue
    start=$SECONDS
    irc=0
    # --quiet is gcloud's answer to -input=false: it never waits for a human.
    # It is not quite the same promise and the difference is worth naming —
    # terraform's -input=false FAILS on a prompt, gcloud's --quiet takes the
    # prompt's default answer. It is safe here because --activation-policy is
    # not one of the flags that builds a confirmation message at all
    # [verified 2026-09-16 against gcloud 578.0.0
    # surface/sql/instances/patch.py: the confirmation is built only for
    # --tier, --enable-database-replication, the Active Directory flags,
    # query-insights length, database flags, and zone moves].
    #
    # Synchronous on purpose (no --async): the seconds recorded should be how
    # long stopping actually took, which is a real number for the session's
    # cost story.
    #
    # </dev/null because this loop's stdin IS the instance list (a herestring
    # at the `done`), and anything in the body that read stdin would swallow
    # instances 2..N — which park would then report as "parked: 1, failed: 0"
    # while the rest kept billing. gcloud does not read stdin on this path
    # today; the redirect makes that irrelevant rather than load-bearing.
    gcloud sql instances patch "$name" \
      --project "$PROJECT_ID" \
      --activation-policy=never \
      --quiet </dev/null >/dev/null || irc=$?
    elapsed=$(( SECONDS - start ))

    if (( irc == 0 )); then
      parked=$(( parked + 1 ))
      note="activation policy NEVER"
      printf '    %s stopped in %ss\n' "$name" "$elapsed"
    else
      failed=$(( failed + 1 ))
      note="activation policy patch failed (exit ${irc})"
      warn "${name}: ${note}"
    fi
    record "$cycle_n" "park" "$name" "$elapsed" "$irc" "$note"
  done <<< "$instances"

  record "$cycle_n" "park" "TOTAL" "$(( SECONDS - total_start ))" \
    "$(( failed > 0 ? 1 : 0 ))" "parked: ${parked}, failed: ${failed}"

  if (( failed > 0 )); then
    die "${failed} instance(s) could not be parked — they are still billing. See the rows above."
  fi
  log "PARK complete — ${parked} instance(s) stopped in $(( (SECONDS - total_start) / 60 ))m $(( (SECONDS - total_start) % 60 ))s"
}

# "Rebuilt" has to mean the platform is back, not that terraform exited 0.
# The honest finish line for C-02/C-04 is every Argo CD Application —
# the root and each child it creates from platform-config — reporting
# Synced and Healthy. Checking only the root would be a confident wrong
# answer: Argo CD dropped Application health from its built-in checks in
# 1.8, so unless 3-argocd's argocd-cm customization restores it, a root
# app reads Healthy while the Crossplane app under it is still failing.
# Listing every Application here means the harness reports the truth even
# if that customization ever regresses, and names the app that is stuck.
#
# Since M2 there is a second half: the durable resources are asked whether
# this rebuild adopted them or made new ones (ADR-0015 §3). On the happy path
# that runs after the Applications converge, because before then Crossplane
# has not finished reconciling and the answer would be about a half-built
# platform. It ALSO runs on the timeout path, marked partial — a rebuild that
# blew the timeout while creating a fresh Cloud SQL instance is the single
# case where the answer matters most, and recording nothing there was the
# cycle least able to afford the silence.
verify_up() {
  local cycle_n="$1" up_start_utc="$2"
  log "verify: waiting for every Application in ${ARGOCD_NS} to report Synced/Healthy"

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

  local start elapsed apps total ready not_ready
  start=$SECONDS
  while true; do
    # One line per Application: name<TAB>sync<TAB>health. Empty if the
    # cluster isn't answering yet or no Application exists.
    apps="$(kubectl get applications -n "$ARGOCD_NS" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' \
      2>/dev/null || echo "")"
    elapsed=$(( SECONDS - start ))

    total=0; ready=0; not_ready=""
    while IFS=$'\t' read -r name sync health; do
      [[ -n "$name" ]] || continue
      total=$(( total + 1 ))
      if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
        ready=$(( ready + 1 ))
      else
        not_ready="${not_ready}${not_ready:+, }${name}(sync=${sync:-<none>} health=${health:-<none>})"
      fi
    done <<< "$apps"

    # The root must be one of them: an empty namespace is "not rebuilt yet",
    # not "nothing to check".
    if (( total > 0 && ready == total )) && grep -q $'^root\t' <<< "$apps"; then
      record "$cycle_n" "up" "verify" "$elapsed" 0 "${ready}/${total} Applications Synced/Healthy"
      printf '    %s/%s Applications Synced/Healthy after %ss\n' "$ready" "$total" "$elapsed"
      record_durable_adoption "$cycle_n" "$up_start_utc"
      return 0
    fi

    if (( elapsed > SYNC_TIMEOUT_SECONDS )); then
      record "$cycle_n" "up" "verify" "$elapsed" 1 "timeout; ${ready}/${total} ready; not ready: ${not_ready:-<no Applications found>}"
      # Snapshot the durable resources before dying. A rebuild that times out
      # BECAUSE it is creating a Cloud SQL instance from scratch instead of
      # adopting one is exactly the case this evidence exists for, and it is
      # also the case that used to produce silence: `die` exits, so neither
      # this row nor do_up's `up`/TOTAL was ever written and the cycle left
      # no durable evidence at all. The qualifier says the platform had not
      # converged when the snapshot was taken, so a reader does not mistake a
      # partial answer for a settled one. The function cannot fail — it
      # swallows listing errors into rc on its own row and returns 0.
      record_durable_adoption "$cycle_n" "$up_start_utc" "partial: taken at verify timeout, platform had not converged"
      warn "not every Application reached Synced/Healthy within ${SYNC_TIMEOUT_SECONDS}s (${ready}/${total} ready)"
      warn "not ready: ${not_ready:-<no Applications found>}"
      # Not a hard failure in the design sense: with root_app_automated_sync
      # = false (the default until 2026-08-13) the root Application sits
      # OutOfSync until a human syncs it, which is precisely a C-02 manual
      # intervention worth recording rather than hiding behind a longer
      # timeout. With it true, a timeout here means a child never converged
      # — the not-ready list above says which one.
      die "Applications never all reached Synced/Healthy — see note above. If root_app_automated_sync is false, this is expected and is the finding."
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
  local start up_start_utc
  start=$SECONDS
  # Wall-clock, not $SECONDS: the adoption check compares this against cloud
  # creation timestamps, so it has to be the same kind of number they are.
  # Taken here rather than at verify time because "did this rebuild create
  # it?" means this whole up, applies included — a resource created during
  # the 2-cluster apply is still this rebuild's doing.
  up_start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_layer "$cycle_n" "up" "2-cluster" "apply"
  run_layer "$cycle_n" "up" "3-argocd" "apply"
  verify_up "$cycle_n" "$up_start_utc"
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
      preflight; do_down "$(next_cycle_number)" ;;
    up)
      preflight; do_up "$(cycle_for_up)" ;;
    cycle)
      preflight
      local n="${2:-1}"
      [[ "$n" =~ ^[0-9]+$ ]] || die "cycle count must be a number, got '${n}'"
      local first c
      first="$(next_cycle_number)"
      for (( i = 0; i < n; i++ )); do
        c=$(( first + i ))
        log "======== CYCLE ${c} ($(( i + 1 )) of ${n}) ========"
        do_down "$c"
        do_up "$c"
      done
      log "All ${n} cycle(s) complete. Results: ${RESULTS_FILE}"
      ;;
    park)
      # Recorded against the cycle most recently opened, not a new one — park
      # is an operator action between cycles, and giving it a number of its
      # own would inflate the count C-02 reports. 0 before the first cycle.
      preflight; do_park "$(last_cycle_number)" ;;
    status)
      preflight; do_status ;;
    *)
      # Print the header block as the usage text. Read to the first
      # non-comment line rather than a hard-coded line range, so growing the
      # header cannot silently truncate the help.
      awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
      exit 1 ;;
  esac
}

main "$@"
