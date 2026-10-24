#!/usr/bin/env bash
#
# collect-cluster-shape.sh
#
# Collects the configuration shape of an OpenShift cluster (versions,
# operators, SCCs, network/storage/security posture, node profiles) as a
# single JSON document, so an equivalent sandbox can be built elsewhere.
#
# Read-only: every cluster access is `get`, `version` or `auth can-i`.
# No secrets, no workload data, no pod/namespace names, no node hostnames,
# no URLs. Sections the account cannot read are reported as "forbidden".
#
# Requires oc (or kubectl) logged in to the target cluster, and jq 1.6+.
#
# Usage:  ./collect-cluster-shape.sh > cluster-shape.json
# Exit:   0 = document produced (gaps possible), 2 = missing prerequisite
#
set -uo pipefail  # no -e: a failing section becomes a labeled gap, not an abort

SCHEMA_VERSION="1.1.1"

if command -v oc >/dev/null 2>&1; then CLI=oc
elif command -v kubectl >/dev/null 2>&1; then CLI=kubectl
else echo "ERROR: neither oc nor kubectl found on PATH" >&2; exit 2; fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH" >&2; exit 2; }

if ! "$CLI" get --raw /version >/dev/null 2>&1; then
  echo "ERROR: cannot reach the cluster API server with '$CLI'. Are you logged in?" >&2
  exit 2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# fetch <outfile> <get-args...>
# Writes {status, data}; status: ok | forbidden | api_not_found | error.
fetch() {
  local out="$1"; shift
  local err
  err="$WORKDIR/err.$$"
  # Data goes through a file: large lists (rendered MachineConfigs) exceed ARG_MAX.
  if "$CLI" get "$@" -o json > "$WORKDIR/fetch_data.json" 2>"$err"; then
    jq '{status:"ok", data:.}' "$WORKDIR/fetch_data.json" > "$out"
  else
    local raw msg status="error"
    raw="$(head -c 500 "$err")"
    case "$raw" in
      *[Ff]orbidden*)                            status="forbidden" ;;
      *"the server doesn't have a resource type"*|*"could not find the requested resource"*|*NotFound*|*"not found"*)
                                                 status="api_not_found" ;;
    esac
    # Arbitrary diagnostics cannot be reliably redacted, especially after
    # truncation. Keep classification local and emit only fixed messages.
    case "$status" in
      forbidden)     msg="read access denied for the executing account (see rbac_preflight)" ;;
      api_not_found) msg="API not present on this cluster" ;;
      *)             msg="resource read failed; inspect the CLI locally" ;;
    esac
    jq -n --arg s "$status" --arg m "$msg" '{status:$s, data:null, message:$m}' > "$out"
  fi
  rm -f "$err"
}

# section <name> <jq-filter> <infile>
# Applies the filter to .data when status is ok. The filters below are where
# all trimming and anonymisation happens.
section() {
  local name="$1" filter="$2" in="$3"
  jq "if .status == \"ok\" then {status:\"ok\", data:(.data | ${filter})} else . end" \
    "$in" > "$WORKDIR/$name.json" 2>"$WORKDIR/$name.err" \
    || jq -n '{status:"error", data:null, message:"section transformation failed"}' \
         > "$WORKDIR/$name.json"
  # An empty fragment would silently drop the section; label it instead.
  [ -s "$WORKDIR/$name.json" ] \
    || jq -n '{status:"error", data:null, message:"section produced no output"}' > "$WORKDIR/$name.json"
}

# Records what this account can read, so "forbidden" gaps below are
# self-explanatory. `auth can-i` checks the account's own permissions and changes nothing.
preflight() {
  local checks=(
    "get clusterversions.config.openshift.io"
    "get infrastructures.config.openshift.io"
    "get clusteroperators.config.openshift.io"
    "get networks.config.openshift.io"
    "get proxies.config.openshift.io"
    "get images.config.openshift.io"
    "get securitycontextconstraints.security.openshift.io"
    "get machineconfigs.machineconfiguration.openshift.io"
    "list subscriptions.operators.coreos.com -A"
    "list clusterserviceversions.operators.coreos.com -A"
    "list nodes"
    "list namespaces"
    "list storageclasses.storage.k8s.io"
    "list networkpolicies.networking.k8s.io -A"
    "list egressfirewalls.k8s.ovn.org -A"
    "list clusterroles.rbac.authorization.k8s.io"
    "list clusterrolebindings.rbac.authorization.k8s.io"
    "list resourcequotas -A"
    "list limitranges -A"
    "list clusterresourcequotas.quota.openshift.io"
    "list pods -A"
    "list imagecontentsourcepolicies.operator.openshift.io"
    "list imagedigestmirrorsets.config.openshift.io"
  )
  local results="[]"
  local c verb rest allowed
  for c in "${checks[@]}"; do
    read -r verb rest <<< "$c"
    # shellcheck disable=SC2086
    if [ "$("$CLI" auth can-i $verb $rest 2>/dev/null)" = "yes" ]; then allowed=true; else allowed=false; fi
    results="$(jq -n --argjson r "$results" --arg c "$c" --argjson a "$allowed" '$r + [{check:$c, allowed:$a}]')"
  done
  echo "$results" > "$WORKDIR/rbac_preflight.json"
}
preflight

CLI_VERSION="$("$CLI" version --client -o json 2>/dev/null | jq -c '.' 2>/dev/null || echo '{}')"
jq -n \
  --arg sv "$SCHEMA_VERSION" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cli "$CLI" \
  --argjson cliv "$CLI_VERSION" \
  '{schema_version:$sv, collected_at:$ts, cli:$cli, cli_version:$cliv}' \
  > "$WORKDIR/meta.json"

# The cluster UUID (.spec.clusterID) is deliberately not collected.
fetch "$WORKDIR/raw.json" clusterversion version
section cluster_version '
  {
    version:       (.status.desired.version // null),
    channel:       (.spec.channel // null),
    capabilities:  (.status.capabilities.enabledCapabilities // []),
    update_history: [ (.status.history // [])[] | {version, state} ]
  }' "$WORKDIR/raw.json"

fetch "$WORKDIR/raw.json" infrastructure cluster
section infrastructure '
  {
    platform:               (.status.platformStatus.type // .status.platform // null),
    control_plane_topology: (.status.controlPlaneTopology // null),
    infrastructure_topology:(.status.infrastructureTopology // null),
    cpu_partitioning:       (.status.cpuPartitioning // null)
  }' "$WORKDIR/raw.json"

fetch "$WORKDIR/raw.json" clusteroperators
section cluster_operators '
  [ .items[] | {
      name: .metadata.name,
      version: ([.status.versions[]? | select(.name=="operator") | .version][0] // null),
      available: ([.status.conditions[]? | select(.type=="Available") | .status][0] // null)
  } ]' "$WORKDIR/raw.json"

fetch "$WORKDIR/raw.json" subscriptions.operators.coreos.com -A
section operators_subscriptions '
  [ .items[] | {
      package:   .spec.name,
      channel:   (.spec.channel // null),
      source:    (.spec.source // null),
      namespace: .metadata.namespace,
      installed_csv: (.status.installedCSV // null)
  } ] | sort_by(.package)' "$WORKDIR/raw.json"

# Drop the per-namespace CSV copies that OLM fans out.
fetch "$WORKDIR/raw.json" clusterserviceversions.operators.coreos.com -A
section operators_csvs '
  [ .items[]
    | select(.metadata.labels["olm.copiedFrom"] == null)
    | {name: .metadata.name, version: (.spec.version // null), phase: (.status.phase // null)}
  ] | unique_by(.name)' "$WORKDIR/raw.json"

# SCC users/groups lists can hold identities: counts only.
fetch "$WORKDIR/raw.json" scc
section scc_definitions '
  [ .items[] | {
      name: .metadata.name,
      priority: (.priority // null),
      allow_privileged:        (.allowPrivilegedContainer // false),
      allow_host_network:      (.allowHostNetwork // false),
      allow_host_pid:          (.allowHostPID // false),
      allow_host_ipc:          (.allowHostIPC // false),
      allow_host_ports:        (.allowHostPorts // false),
      allow_privilege_escalation: (.allowPrivilegeEscalation // null),
      read_only_root_fs:       (.readOnlyRootFilesystem // false),
      run_as_user_strategy:    (.runAsUser.type // null),
      selinux_strategy:        (.seLinuxContext.type // null),
      fsgroup_strategy:        (.fsGroup.type // null),
      volumes:                 (.volumes // []),
      allowed_capabilities:    (.allowedCapabilities // []),
      required_drop_capabilities: (.requiredDropCapabilities // []),
      granted_users_count:     ((.users // []) | length),
      granted_groups_count:    ((.groups // []) | length),
      granted_to_all_authenticated: ((.groups // []) | index("system:authenticated") != null)
  } ] | sort_by(.name)' "$WORKDIR/raw.json"

# Only the openshift.io/scc annotation is read per pod, aggregated to
# {scc: pod_count}. Pod names, namespaces and images stay on the cluster.
if scc_usage_raw="$("$CLI" get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}' 2>"$WORKDIR/scc.err")"; then
  {
    printf '%s\n' "$scc_usage_raw" | sed '/^$/d' | sort | uniq -c \
      | jq -R -n '[inputs | capture("^ *(?<n>[0-9]+) (?<scc>.+)$") | {(.scc): (.n|tonumber)}] | add // {}' \
      | jq '{status:"ok", data:{pods_per_scc: .}}' > "$WORKDIR/scc_usage.json"
  } 2>"$WORKDIR/scc_transform.err" \
    || jq -n '{status:"error", data:null, message:"section transformation failed"}' > "$WORKDIR/scc_usage.json"
else
  case "$(head -c 300 "$WORKDIR/scc.err")" in
    *[Ff]orbidden*) s=forbidden; msg="read access denied for the executing account (see rbac_preflight)" ;;
    *)              s=error;     msg="resource read failed; inspect the CLI locally" ;;
  esac
  jq -n --arg s "$s" --arg m "$msg" '{status:$s, data:null, message:$m}' > "$WORKDIR/scc_usage.json"
fi

# OpenShift 4.11+ grants default SCC use through ClusterRoles bound to
# groups; the legacy users/groups fields stay empty. Output is limited to
# SCC names granted to the two broad groups. Binding subjects are never emitted.
fetch "$WORKDIR/raw_roles.json" clusterroles
fetch "$WORKDIR/raw_bindings.json" clusterrolebindings
if jq -e '.status=="ok"' "$WORKDIR/raw_roles.json" >/dev/null \
   && jq -e '.status=="ok"' "$WORKDIR/raw_bindings.json" >/dev/null; then
  # shellcheck disable=SC2016  # $b/$sccRoles etc. are jq variables
  jq -n --slurpfile roles "$WORKDIR/raw_roles.json" --slurpfile bindings "$WORKDIR/raw_bindings.json" '
    ($roles[0].data.items // []) as $r
    | ($bindings[0].data.items // []) as $b
    | def use_rule: ((.apiGroups // []) | (index("security.openshift.io") or index("*")))
        and ((.resources // []) | (index("securitycontextconstraints") or index("*")))
        and ((.verbs // []) | (index("use") or index("*")));
      [ $r[] | select(any(.rules[]?; use_rule))
        | {role: .metadata.name,
           # a use rule without resourceNames grants ALL SCCs -> "*"
           sccs: ([.rules[]? | select(use_rule)
                   | if (.resourceNames // []) == [] then ["*"] else .resourceNames end]
                  | flatten | unique)} ] as $sccRoles
    | def grantedTo(g):
        ([ $b[] | select(any(.subjects[]?; .kind == "Group" and .name == g)) | .roleRef.name ]) as $rn
        | [ $sccRoles[] | select(.role | IN($rn[])) | .sccs[] ] | unique;
    {status: "ok", data: {
       granted_to_all_authenticated: grantedTo("system:authenticated"),
       granted_to_all_service_accounts: grantedTo("system:serviceaccounts")
    }}' > "$WORKDIR/scc_rbac_grants.json" 2>"$WORKDIR/scc_rbac.err" \
    || jq -n '{status:"error", data:null, message:"section transformation failed"}' > "$WORKDIR/scc_rbac_grants.json"
else
  jq -s '{status: (map(.status) | if index("forbidden") then "forbidden"
                   elif index("api_not_found") then "api_not_found" else "error" end),
          data: null,
          message: "clusterroles/clusterrolebindings not readable"}' \
    "$WORKDIR/raw_roles.json" "$WORKDIR/raw_bindings.json" > "$WORKDIR/scc_rbac_grants.json"
fi

# Namespace names are never emitted: counts per PSA level, split into
# platform (openshift-*, kube-*, default) and user namespaces.
fetch "$WORKDIR/raw.json" namespaces
section pod_security '
  def bucket: if (.metadata.name | test("^(openshift-|kube-|default$|openshift$)")) then "platform" else "user" end;
  def lvl(k): (.metadata.labels[k] // "unset");
  {
    namespace_count: {
      platform: ([.items[] | select(bucket=="platform")] | length),
      user:     ([.items[] | select(bucket=="user")] | length)
    },
    enforce_levels: ([.items[] | {b: bucket, l: lvl("pod-security.kubernetes.io/enforce")}]
                     | group_by(.b) | map({(.[0].b): (group_by(.l) | map({(.[0].l): length}) | add)}) | add // {}),
    warn_levels:    ([.items[] | {b: bucket, l: lvl("pod-security.kubernetes.io/warn")}]
                     | group_by(.b) | map({(.[0].b): (group_by(.l) | map({(.[0].l): length}) | add)}) | add // {}),
    audit_levels:   ([.items[] | {b: bucket, l: lvl("pod-security.kubernetes.io/audit")}]
                     | group_by(.b) | map({(.[0].b): (group_by(.l) | map({(.[0].l): length}) | add)}) | add // {})
  }' "$WORKDIR/raw.json"

# Pod/service CIDRs are cluster-internal and needed for the replica, so they are kept.
fetch "$WORKDIR/raw.json" network.config.openshift.io cluster
section network '
  {
    cni_plugin:      (.status.networkType // .spec.networkType // null),
    cluster_network: (.status.clusterNetwork // .spec.clusterNetwork // []),
    service_network: (.status.serviceNetwork // .spec.serviceNetwork // []),
    cluster_network_mtu: (.status.clusterNetworkMTU // null)
  }' "$WORKDIR/raw.json"

# Structure only: no names, namespaces, selectors, ports or CIDRs.
fetch "$WORKDIR/raw.json" networkpolicies -A
section network_policies '
  {
    total: (.items | length),
    namespaces_with_policies: ([.items[].metadata.namespace] | unique | length),
    policies: [ .items[] | {
        policy_types: (.spec.policyTypes // []),
        selects_all_pods: ((.spec.podSelector // {}) == {}),
        ingress_rule_count: ((.spec.ingress // []) | length),
        egress_rule_count:  ((.spec.egress // []) | length),
        is_default_deny: (((.spec.podSelector // {}) == {})
                          and ((.spec.ingress // []) | length == 0)
                          and ((.spec.egress // []) | length == 0))
    } ]
  }' "$WORKDIR/raw.json"

# Counts only: egress rule CIDRs and DNS names are not collected.
fetch "$WORKDIR/raw.json" egressnetworkpolicies.network.openshift.io -A
section egress_network_policies '
  { total: (.items | length),
    rules_total: ([.items[].spec.egress // [] | length] | add // 0) }' "$WORKDIR/raw.json"

fetch "$WORKDIR/raw.json" egressfirewalls.k8s.ovn.org -A
section egress_firewalls '
  { total: (.items | length),
    rules_total: ([.items[].spec.egress // [] | length] | add // 0) }' "$WORKDIR/raw.json"

# Parameter keys only: values can embed backend endpoints or IDs.
fetch "$WORKDIR/raw.json" storageclasses
section storage_classes '
  [ .items[] | {
      name: .metadata.name,
      provisioner: .provisioner,
      reclaim_policy: (.reclaimPolicy // null),
      volume_binding_mode: (.volumeBindingMode // null),
      allow_volume_expansion: (.allowVolumeExpansion // false),
      is_default: ((.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false") == "true"),
      parameter_keys: ((.parameters // {}) | keys)
  } ] | sort_by(.name)' "$WORKDIR/raw.json"

# Hostnames are replaced with node-0..N; no IPs.
fetch "$WORKDIR/raw.json" nodes
section nodes '
  [ .items | sort_by(.metadata.name) | to_entries[] | {
      id: ("node-" + (.key | tostring)),
      roles: ([.value.metadata.labels | to_entries[]
               | select(.key | startswith("node-role.kubernetes.io/"))
               | .key | sub("node-role.kubernetes.io/"; "")] | sort),
      architecture:      .value.status.nodeInfo.architecture,
      os_image:          .value.status.nodeInfo.osImage,
      kernel_version:    .value.status.nodeInfo.kernelVersion,
      kubelet_version:   .value.status.nodeInfo.kubeletVersion,
      container_runtime: .value.status.nodeInfo.containerRuntimeVersion,
      capacity: {
        cpu:    .value.status.capacity.cpu,
        memory: .value.status.capacity.memory,
        pods:   .value.status.capacity.pods
      },
      allocatable: {
        cpu:    .value.status.allocatable.cpu,
        memory: .value.status.allocatable.memory
      },
      instance_type: (.value.metadata.labels["node.kubernetes.io/instance-type"] // null),
      zone:   (.value.metadata.labels["topology.kubernetes.io/zone"] // null),
      region: (.value.metadata.labels["topology.kubernetes.io/region"] // null)
  } ]' "$WORKDIR/raw.json"

# Derived from the node list fetched above (raw.json still holds it).
# shellcheck disable=SC2016  # $n/$cp/$infra are jq variables, not shell
section topology '
  def roles: [(.metadata.labels // {}) | to_entries[]
              | select(.key | startswith("node-role.kubernetes.io/"))
              | .key | sub("node-role.kubernetes.io/"; "")];
  def is_cp: (roles | any(. == "master" or . == "control-plane"));
  def is_infra: (roles | any(. == "infra"));
  def cp_unschedulable: ([(.spec.taints // [])[]
    | select((.key == "node-role.kubernetes.io/master" or .key == "node-role.kubernetes.io/control-plane")
             and .effect == "NoSchedule")] | length > 0);
  .items as $n
  | [$n[] | select(is_cp)] as $cp
  | [$n[] | select(is_infra)] as $infra
  | [$n[] | select((is_cp or is_infra) | not)] as $dedicated_workers
  | {
      total_nodes: ($n | length),
      control_plane_count: ($cp | length),
      infra_count: ($infra | length),
      worker_count: ([$n[] | select(roles | any(. == "worker"))] | length),
      dedicated_worker_count: ($dedicated_workers | length),
      ha_classification: (
        if ($n | length) == 1 then "single-node"
        elif ($cp | length) == 1 then "single-control-plane"
        elif ($cp | length) == 3 and ($n | length) == 3 then "compact"
        elif ($cp | length) >= 3 and ($dedicated_workers | length) >= 1 then "standard"
        else "other" end),
      control_plane_schedulable: ([$cp[] | select(cp_unschedulable | not)] | length > 0),
      infra_separated_from_workers: (($infra | length) > 0),
      infra_nodes_tainted: (
        if ($infra | length) == 0 then null
        else ([$infra[] | select([(.spec.taints // [])[] | select(.key | test("infra"))] | length > 0)]
              | length) == ($infra | length) end),
      zone_spread: {
        distinct_zone_count: ([$n[] | (.metadata.labels["topology.kubernetes.io/zone"] // "unlabeled")] | unique | length),
        nodes_per_zone: (([$n[] | {z: (.metadata.labels["topology.kubernetes.io/zone"] // "unlabeled")}]
                          | group_by(.z) | map({(.[0].z): length}) | add) // {})
      },
      distinct_region_count: ([$n[] | (.metadata.labels["topology.kubernetes.io/region"] // "unlabeled")] | unique | length)
    }' "$WORKDIR/raw.json"

# Spec shapes deduplicated, no namespace names. scopeSelector is reduced to
# a flag because its expressions can name custom PriorityClasses.
fetch "$WORKDIR/raw.json" resourcequotas -A
section resource_quotas '
  { total: (.items | length),
    namespaces_with_quotas: ([.items[].metadata.namespace] | unique | length),
    distinct_specs: ([.items[].spec
                      | {hard: (.hard // {}), scopes: (.scopes // []),
                         has_scope_selector: has("scopeSelector")}]
                     | group_by(.) | map({spec: .[0], applied_count: length})) }' "$WORKDIR/raw.json"

fetch "$WORKDIR/raw.json" limitranges -A
section limit_ranges '
  { total: (.items | length),
    distinct_specs: ([.items[].spec] | group_by(.) | map({spec: .[0], applied_count: length})) }' "$WORKDIR/raw.json"

fetch "$WORKDIR/raw.json" clusterresourcequotas.quota.openshift.io
section cluster_resource_quotas '
  { total: (.items | length),
    distinct_specs: ([.items[].spec.quota] | group_by(.) | map({spec: .[0], applied_count: length})) }' "$WORKDIR/raw.json"

# .spec.fips from the rendered MachineConfigs; often needs elevated read.
fetch "$WORKDIR/raw.json" machineconfigs.machineconfiguration.openshift.io
section fips '
  { fips_enabled: ([.items[].spec.fips // false] | any) }' "$WORKDIR/raw.json"

# Booleans and counts only: proxy URLs are not collected.
fetch "$WORKDIR/raw.json" proxy cluster
section proxy '
  {
    http_proxy_configured:  ((.spec.httpProxy  // "") != ""),
    https_proxy_configured: ((.spec.httpsProxy // "") != ""),
    no_proxy_entry_count:   ((.spec.noProxy // "") | if . == "" then 0 else (split(",") | length) end),
    trusted_ca_configured:  ((.spec.trustedCA.name // "") != "")
  }' "$WORKDIR/raw.json"

# Registry hostnames are not collected.
fetch "$WORKDIR/raw.json" image.config.openshift.io cluster
section image_config '
  {
    allowed_registries_count: ((.spec.registrySources.allowedRegistries // []) | length),
    blocked_registries_count: ((.spec.registrySources.blockedRegistries // []) | length),
    insecure_registries_count:((.spec.registrySources.insecureRegistries // []) | length),
    additional_trusted_ca:    ((.spec.additionalTrustedCA.name // "") != "")
  }' "$WORKDIR/raw.json"

# Mirror sets indicate a disconnected install. Counts only.
fetch "$WORKDIR/raw.json" imagecontentsourcepolicies.operator.openshift.io
section icsp '{ count: (.items | length) }' "$WORKDIR/raw.json"
fetch "$WORKDIR/raw.json" imagedigestmirrorsets.config.openshift.io
section idms '{ count: (.items | length) }' "$WORKDIR/raw.json"
fetch "$WORKDIR/raw.json" imagetagmirrorsets.config.openshift.io
section itms '{ count: (.items | length) }' "$WORKDIR/raw.json"

fetch "$WORKDIR/raw.json" operatorhub cluster
section operator_hub '
  { default_sources_disabled: (.spec.disableAllDefaultSources // false) }' "$WORKDIR/raw.json"

jq -n \
  --slurpfile meta                  "$WORKDIR/meta.json" \
  --slurpfile rbac                  "$WORKDIR/rbac_preflight.json" \
  --slurpfile cluster_version       "$WORKDIR/cluster_version.json" \
  --slurpfile infrastructure        "$WORKDIR/infrastructure.json" \
  --slurpfile cluster_operators     "$WORKDIR/cluster_operators.json" \
  --slurpfile subs                  "$WORKDIR/operators_subscriptions.json" \
  --slurpfile csvs                  "$WORKDIR/operators_csvs.json" \
  --slurpfile scc_defs              "$WORKDIR/scc_definitions.json" \
  --slurpfile scc_usage             "$WORKDIR/scc_usage.json" \
  --slurpfile scc_rbac              "$WORKDIR/scc_rbac_grants.json" \
  --slurpfile pod_security          "$WORKDIR/pod_security.json" \
  --slurpfile network               "$WORKDIR/network.json" \
  --slurpfile netpols               "$WORKDIR/network_policies.json" \
  --slurpfile egress_np             "$WORKDIR/egress_network_policies.json" \
  --slurpfile egress_fw             "$WORKDIR/egress_firewalls.json" \
  --slurpfile storage               "$WORKDIR/storage_classes.json" \
  --slurpfile nodes                 "$WORKDIR/nodes.json" \
  --slurpfile topology              "$WORKDIR/topology.json" \
  --slurpfile quotas                "$WORKDIR/resource_quotas.json" \
  --slurpfile limits                "$WORKDIR/limit_ranges.json" \
  --slurpfile crq                   "$WORKDIR/cluster_resource_quotas.json" \
  --slurpfile fips                  "$WORKDIR/fips.json" \
  --slurpfile proxy                 "$WORKDIR/proxy.json" \
  --slurpfile image_config          "$WORKDIR/image_config.json" \
  --slurpfile icsp                  "$WORKDIR/icsp.json" \
  --slurpfile idms                  "$WORKDIR/idms.json" \
  --slurpfile itms                  "$WORKDIR/itms.json" \
  --slurpfile operator_hub          "$WORKDIR/operator_hub.json" \
  '{
    meta:            $meta[0],
    rbac_preflight:  $rbac[0],
    cluster_version: $cluster_version[0],
    infrastructure:  $infrastructure[0],
    cluster_operators: $cluster_operators[0],
    operators: { subscriptions: $subs[0], cluster_service_versions: $csvs[0] },
    security: {
      scc_definitions: $scc_defs[0],
      scc_usage:       $scc_usage[0],
      scc_rbac_grants: $scc_rbac[0],
      pod_security:    $pod_security[0]
    },
    network: {
      cluster_network:         $network[0],
      network_policies:        $netpols[0],
      egress_network_policies: $egress_np[0],
      egress_firewalls:        $egress_fw[0]
    },
    storage_classes: $storage[0],
    nodes:           $nodes[0],
    topology:        $topology[0],
    quotas: {
      resource_quotas:         $quotas[0],
      limit_ranges:            $limits[0],
      cluster_resource_quotas: $crq[0]
    },
    environment: {
      fips:         $fips[0],
      proxy:        $proxy[0],
      image_config: $image_config[0],
      image_content_source_policies: $icsp[0],
      image_digest_mirror_sets:      $idms[0],
      image_tag_mirror_sets:         $itms[0],
      operator_hub: $operator_hub[0]
    }
  }'
