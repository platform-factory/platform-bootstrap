# Same formula 0-foundation used to name the bucket in the first place
# (see its main.tf), recomputed here because this is a separate state file
# with no way to import that layer's locals directly — only its outputs,
# and we need the bucket name before we can read those.
locals {
  tfstate_bucket = "${var.project_id}-tfstate"
}

# The umbrella Google Group the cluster resolves RBAC group membership
# against (gke.tf's authenticator_groups_config). Read from 1-network's
# passthrough rather than declared as a variable here, for the same reason
# every other cross-layer fact is: 0-foundation owns the group's IAM grant
# (ADR-0012 §5), so foundation is where the value is set, and each layer
# reads only its immediate predecessor.
#
# try(..., null) rather than a direct read because the passthrough is newer
# than this layer's state and because the group itself may not exist yet —
# creating Workspace groups is a manual admin task outside the paved road
# (ADR-0012 §3), deliberately recorded rather than hidden. Null means the
# dynamic block in gke.tf creates nothing and the cluster comes up exactly
# as it did in M1.
#
# TURNING THIS ON LATER TAKES THREE APPLIES, IN ORDER, AND SKIPPING THE
# MIDDLE ONE FAILS SILENTLY. The value is 0-foundation's variable,
# republished by 1-network. Remote state reads the last APPLIED state, so
# setting gke_security_group in foundation's tfvars and applying only
# foundation leaves 1-network's state still holding the old null; try()
# returns null, gke.tf's dynamic block renders nothing, and the cluster comes
# up with no authenticator_groups_config and no error anywhere. The
# consequence is the one gke.tf warns about — every RoleBinding the System
# Composition writes on <team>@thecloudgeek.io matches nobody, so C-06
# measures nothing while appearing to pass. The order is:
#   1. terraform -chdir=layers/0-foundation apply   (sets the value)
#   2. terraform -chdir=layers/1-network apply      (republishes it)
#   3. rebuild 2-cluster                            (reads it)
# Step 2 is a MANUAL apply: 1-network is persistent, and scripts/cycle.sh
# refuses to touch it (DISPOSABLE_LAYERS is 2-cluster and 3-argocd only), so
# no down/up will ever do it for you. It is also a terraform apply on a
# persistent layer after M1, i.e. a C-01 crossing, and it is counted as one.
locals {
  gke_security_group = try(data.terraform_remote_state.network.outputs.gke_security_group, null)
}
