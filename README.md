# lorasis-oc-collector

Read-only OpenShift cluster shape discovery, by Lorasis.

`collect-cluster-shape.sh` reads the configuration shape of an OpenShift
cluster and prints it as one JSON document. The output describes the cluster
well enough to replicate an equivalent environment in a lab, without giving
anyone access to the cluster itself: the operators review the script, run it
with an account of their choosing, check the output, and share a single file.

The script is plain bash calling `oc` (or `kubectl`) and `jq`. There are no
other binaries and no network traffic except to the cluster's own API
server. It never writes to the cluster.

## What it collects

| Section | Contents | Privacy handling |
|---|---|---|
| `cluster_version` | OCP version, channel, enabled capabilities, upgrade history (version numbers only) | The cluster UUID is not collected. |
| `infrastructure` | Platform type (BareMetal, VSphere, ...) and control plane topology | One enum each. API and console URLs are not collected. |
| `cluster_operators` | Core operator names, versions, availability | Red Hat components, identical on every cluster of the same version. |
| `operators` | OLM subscriptions (package, channel, catalog source, install namespace) and CSV versions | Install namespaces are platform configuration. Operator settings are not read. |
| `security.scc_definitions` | Capability and host-access flags per SCC | User and group grant lists are reduced to counts, so no identities appear. |
| `security.scc_rbac_grants` | Which SCCs are granted to `system:authenticated` and `system:serviceaccounts` through ClusterRole `use` bindings | Only SCC names for these two groups. Binding subjects are never emitted. |
| `security.scc_usage` | Pod count per SCC | Reads only the `openshift.io/scc` annotation of each pod. Pod names, namespaces and images stay on the cluster. |
| `security.pod_security` | How many namespaces sit at each PSA level, split platform vs user | Counts only. Namespace names are never emitted. |
| `network.cluster_network` | CNI plugin, pod and service CIDRs, MTU | Cluster-internal addressing, needed for a faithful replica. |
| `network.network_policies` | Count plus per-policy structure: policy types, rule counts, default-deny flag | Names, namespaces, selectors, ports and CIDRs are not collected. |
| `network.egress_*` | Object and rule counts for EgressNetworkPolicy and EgressFirewall | The actual egress rules (CIDRs, DNS names) are not collected. |
| `storage_classes` | Name, provisioner, reclaim and binding modes, default flag, parameter keys | Parameter values can embed backend endpoints, so only keys are kept. |
| `nodes` | Roles, architecture, OS/kernel/kubelet/runtime versions, CPU and memory capacity, zone and region labels | Hostnames are replaced with `node-0`, `node-1`, ... No IPs. |
| `topology` | Node counts by role, HA classification, control plane schedulability, infra separation, zone spread | Derived from the same anonymised node data. |
| `quotas` | Deduplicated quota and limit range spec shapes, with how often each applies | Namespace names are not emitted. |
| `environment` | FIPS flag, proxy configured yes/no, registry restriction counts, mirror set counts, OperatorHub source flag | Booleans and counts. Proxy URLs and registry hostnames are not collected. |
| `rbac_preflight` | `oc auth can-i` result for each resource the script reads | A check of the executing account's own permissions, so gaps in the output explain themselves. |

The output never contains Secrets, ConfigMap contents, pod logs, workload
data, pod or namespace names, node hostnames, user or service account
identities, proxy URLs, egress or firewall rule contents, or internal
hostnames of any kind. This holds on error paths too: unreadable sections
carry a fixed message, and unexpected error text passes through a redaction
step that strips identities, URLs and IP addresses before it can reach the
output.

## Auditing the script

Two greps answer most of the trust question:

```bash
# 1. Every use of the CLI. The cluster accesses among them are only
#    'get', 'version' and 'auth can-i'.
grep -n '"\$CLI"' collect-cluster-shape.sh

# 2. Mutating verbs and secret access. Produces no output at all.
grep -nwE 'create|apply|patch|delete|exec|edit|scale|secret|curl|wget' collect-cluster-shape.sh
```

`oc auth can-i` runs a SelfSubjectAccessReview, a permission check on the
executing account itself. It creates no persistent object.

## Running it

You need `oc` (or `kubectl`) logged in to the target cluster, and `jq`.

```bash
./collect-cluster-shape.sh > cluster-shape.json
```

A few seconds on a small cluster. On large clusters the pod listing for the
SCC usage count dominates and can take a minute or two.

`cluster-shape.json` is one human-readable JSON file, usually between 10 and
60 KB, and is the only artifact the script produces. It is worth reading in
full before sharing it anywhere.

### Permissions

The script runs with whatever read access the executing account has. Any
section the account cannot read is reported as `"status": "forbidden"`
instead of failing the run. A complete document
needs cluster-scope get/list on the config.openshift.io group,
securitycontextconstraints, OLM subscriptions and CSVs, machineconfigs (for
the FIPS flag only), clusterroles and clusterrolebindings (SCC grant posture;
no binding subjects are emitted), nodes, namespaces, storageclasses,
networkpolicies, egressfirewalls, quotas and limitranges, and pod listing
(annotations only). The built-in `cluster-reader` role covers all of it.

If machineconfigs are not readable, the FIPS section shows up as a gap; the
FIPS state then has to be established some other way.

## Section statuses

| Status | Meaning |
|---|---|
| `ok` | Collected. See `data`. |
| `forbidden` | The account lacks read permission. Cross-check `rbac_preflight`. |
| `api_not_found` | The API does not exist on this cluster. Expected in some cases, for example `egressnetworkpolicies` on an OVN cluster. |
| `error` | Anything else. `message` holds the CLI error, truncated and redacted. |

The field-level schema is in [SCHEMA.md](SCHEMA.md).

## How it was tested

The script has been run against a real OpenShift 4.22.1 cluster (OpenShift Local,
OVN-Kubernetes, single node) configured with restricted Pod Security
enforcement on tenant namespaces, default-deny NetworkPolicies with explicit
allow rules, resource quotas and limit ranges, and default SCC posture. The
policy enforcement was confirmed live: a privileged pod was rejected by SCC
admission, a non-compliant pod was rejected by PSA, and cross-namespace
traffic timed out while same-namespace traffic got HTTP 200.

Results: 25 of 26 sections `ok`, with the single `api_not_found` being the
expected one on an OVN cluster. Section contents matched the configured
state, including the SCC distribution across the platform's own pods, PSA
levels over 67 namespaces, default-deny detection among the 107
NetworkPolicies a stock cluster ships, and quota deduplication. A leak check
against the cluster's real identifiers (node name, node IP, cluster
hostnames, admin password, tenant namespace and pod names, user names,
service account identities) found none of them in the output.
`example-output.json` is that run's output, verbatim.

Separately, a low-privilege service account run produced valid output with
correct `forbidden` gaps, and the topology classifier was tested against
single-node, compact, standard and single-control-plane node sets.

Two caveats. FIPS cannot be enabled on OpenShift Local, so the FIPS section
has only been seen reporting `false` from real MachineConfig data. And the
test cluster is a single node, so the multi-node topology shapes were
verified with constructed node lists rather than a live multi-node cluster.
