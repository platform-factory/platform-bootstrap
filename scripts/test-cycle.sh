#!/usr/bin/env bash
#
# test-cycle.sh — tests for cycle.sh's M2b functions, at the desk.
#
# Why: every change to cycle.sh during the engine swap has to work on BOTH
# engines (ADR-0017 §1), because the swap is tested forward to Config
# Connector and back to Crossplane with the same harness. A bug that shows up
# only on one engine would surface in the middle of a paid session, between
# legs, where fixing it would itself change the thing being measured. So the
# functions are fed Application lists in both engines' shapes here, before
# either session runs.
#
# The two lists are hand-written from what each engine creates:
#   Crossplane (M2):    the root, six platform children, the `systems`
#                       Application, and one Application per System, named
#                       after it and carrying the system label.
#   Config Connector:   the root, three platform children (the tenants'
#                       ApplicationSet is not an Application), and three
#                       Applications per System: <system>-system, <system>,
#                       <system>-claims, all carrying the system label.
#
# Usage: ./scripts/test-cycle.sh   (no cluster, no cloud, no credentials)

set -euo pipefail

# shellcheck source=cycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/cycle.sh"

failures=0
check() {
  local label="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n     want: %q\n     got:  %q\n' "$label" "$want" "$got"
    failures=$(( failures + 1 ))
  fi
}

T=$'\t'

crossplane_healthy="root${T}Synced${T}Healthy${T}
crossplane${T}Synced${T}Healthy${T}
crossplane-providers${T}Synced${T}Healthy${T}
crossplane-platform${T}Synced${T}Healthy${T}
kyverno${T}Synced${T}Healthy${T}
kyverno-policies${T}Synced${T}Healthy${T}
compositions${T}Synced${T}Healthy${T}
systems${T}Synced${T}Healthy${T}
svc-hello${T}Synced${T}Healthy${T}svc-hello
svc-ledger${T}Synced${T}Healthy${T}svc-ledger"

cnrm_healthy="root${T}Synced${T}Healthy${T}
config-connector${T}Synced${T}Healthy${T}
kyverno${T}Synced${T}Healthy${T}
kyverno-policies${T}Synced${T}Healthy${T}
svc-hello-system${T}Synced${T}Healthy${T}svc-hello
svc-hello${T}Synced${T}Healthy${T}svc-hello
svc-hello-claims${T}Synced${T}Healthy${T}svc-hello
svc-ledger-system${T}Synced${T}Healthy${T}svc-ledger
svc-ledger${T}Synced${T}Healthy${T}svc-ledger
svc-ledger-claims${T}Synced${T}Healthy${T}svc-ledger"

# The ApplicationSet generated nothing: every Application that exists is
# healthy, which is exactly the case the tenant count exists to catch.
cnrm_nothing_generated="root${T}Synced${T}Healthy${T}
config-connector${T}Synced${T}Healthy${T}
kyverno${T}Synced${T}Healthy${T}
kyverno-policies${T}Synced${T}Healthy${T}"

cnrm_claims_waiting="root${T}Synced${T}Healthy${T}
config-connector${T}Synced${T}Healthy${T}
svc-hello-system${T}Synced${T}Healthy${T}svc-hello
svc-hello${T}Synced${T}Healthy${T}svc-hello
svc-hello-claims${T}OutOfSync${T}${T}svc-hello"

echo "== summarize_apps: total, ready, systems, not ready"
check "Crossplane, all healthy, two tenants" \
  "$(summarize_apps <<< "$crossplane_healthy")" "10${T}10${T}2${T}"
check "Config Connector, all healthy, two tenants (three Applications each)" \
  "$(summarize_apps <<< "$cnrm_healthy")" "10${T}10${T}2${T}"
check "Config Connector, the ApplicationSet generated nothing" \
  "$(summarize_apps <<< "$cnrm_nothing_generated")" "4${T}4${T}0${T}"
check "Config Connector, one claims Application not ready, health empty" \
  "$(summarize_apps <<< "$cnrm_claims_waiting")" "5${T}4${T}1${T}svc-hello-claims(sync=OutOfSync health=<none>)"
check "an empty list (cluster not answering yet)" \
  "$(summarize_apps <<< "")" "0${T}0${T}0${T}"

echo "== count_tenant_names: GitHub's contents API for tenants/"
listing='[
  {
    "name": "svc-hello.yaml",
    "path": "tenants/svc-hello.yaml",
    "type": "file"
  },
  {
    "name": "svc-ledger.yaml",
    "path": "tenants/svc-ledger.yaml",
    "type": "file"
  },
  {
    "name": "notes.yml",
    "path": "tenants/notes.yml",
    "type": "file"
  },
  {
    "name": "archive",
    "path": "tenants/archive",
    "type": "dir"
  }
]'
check "two .yaml files; a .yml file and a folder do not count" \
  "$(count_tenant_names <<< "$listing")" "2"
check "an empty listing counts zero" "$(count_tenant_names <<< "")" "0"

echo
if (( failures > 0 )); then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "every check passed."
