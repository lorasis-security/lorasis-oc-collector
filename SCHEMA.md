# cluster-shape.json: output schema

Schema version: 1.1.0 (`meta.schema_version`). Consumers must tolerate
added fields within a major version; removed/renamed fields bump the major.
1.1.0 adds the `topology` and `security.scc_rbac_grants` sections (additive).

## Section wrapper

Every section (marked `§` below) is wrapped as:

```json
{
  "status": "ok | forbidden | api_not_found | error",
  "data":   <section payload, null unless status == "ok">,
  "message": "<present only when status != ok: fixed reason text for
               forbidden/api_not_found; for error, CLI error text with
               identities, URLs and IP addresses redacted>"
}
```

Consumers MUST branch on `status` before reading `data`. `forbidden` and
`api_not_found` are expected, non-fatal gap markers.

## Top-level structure

```
{
  meta: {
    schema_version: string        // "1.1.0"
    collected_at:   string        // UTC ISO-8601
    cli:            "oc" | "kubectl"
    cli_version:    object        // raw `<cli> version --client -o json`, {} if unavailable
  },

  rbac_preflight: [                    // not wrapped, always present
    { check: string,                   // e.g. "get clusterversions.config.openshift.io"
      allowed: boolean }
  ],

  cluster_version: § {
    version:        string | null      // e.g. "4.16.21"
    channel:        string | null      // e.g. "stable-4.16"
    capabilities:   string[]           // enabled capability names
    update_history: [ { version: string, state: string } ]
  },

  infrastructure: § {
    platform:                string | null   // "BareMetal" | "VSphere" | "AWS" | "None" | ...
    control_plane_topology:  string | null   // "HighlyAvailable" | "SingleReplica" | ...
    infrastructure_topology: string | null
    cpu_partitioning:        string | null   // "None" | "AllNodes"
  },

  cluster_operators: § [
    { name: string, version: string | null, available: "True" | "False" | null }
  ],

  operators: {
    subscriptions: § [                 // sorted by package
      { package: string,               // OLM package name
        channel: string | null,
        source: string | null,         // catalog source, e.g. "redhat-operators"
        namespace: string,             // install namespace (platform config)
        installed_csv: string | null }
    ],
    cluster_service_versions: § [      // copied CSVs deduplicated
      { name: string, version: string | null, phase: string | null }
    ]
  },

  security: {
    scc_definitions: § [               // sorted by name
      { name: string,
        priority: number | null,
        allow_privileged: boolean,
        allow_host_network: boolean,
        allow_host_pid: boolean,
        allow_host_ipc: boolean,
        allow_host_ports: boolean,
        allow_privilege_escalation: boolean | null,
        read_only_root_fs: boolean,
        run_as_user_strategy: string | null,   // "MustRunAsRange" | "RunAsAny" | ...
        selinux_strategy: string | null,
        fsgroup_strategy: string | null,
        volumes: string[],
        allowed_capabilities: string[],
        required_drop_capabilities: string[],
        granted_users_count: number,           // identities NOT included
        granted_groups_count: number,
        granted_to_all_authenticated: boolean }// legacy .groups field only;
    ],                                         // see scc_rbac_grants for the
                                               // modern RBAC-based grants
    scc_rbac_grants: § {                       // SCCs granted via ClusterRole
                                               // "use" verb + group binding
      granted_to_all_authenticated: string[],  // SCC names bound to
                                               // system:authenticated;
                                               // "*" = a use-rule granting
                                               // ALL SCCs
      granted_to_all_service_accounts: string[]// ... to system:serviceaccounts
    },
    scc_usage: § {
      pods_per_scc: { [scc_name: string]: number }   // aggregate counts only
    },
    pod_security: § {
      namespace_count: { platform: number, user: number },
      // "platform" = names matching ^(openshift-|kube-|default$|openshift$); "user" = rest.
      // Level keys: "restricted" | "baseline" | "privileged" | "unset"
      enforce_levels: { platform?: {[level]: number}, user?: {[level]: number} },
      warn_levels:    { ... same shape ... },
      audit_levels:   { ... same shape ... }
    }
  },

  network: {
    cluster_network: § {
      cni_plugin:      string | null     // "OVNKubernetes" | "OpenShiftSDN" | ...
      cluster_network: [ { cidr: string, hostPrefix: number } ],
      service_network: string[],
      cluster_network_mtu: number | null
    },
    network_policies: § {                // structural summaries; no names/selectors/CIDRs
      total: number,
      namespaces_with_policies: number,
      policies: [
        { policy_types: string[],        // ["Ingress"] / ["Ingress","Egress"]
          selects_all_pods: boolean,     // empty podSelector
          ingress_rule_count: number,
          egress_rule_count: number,
          is_default_deny: boolean }
      ]
    },
    egress_network_policies: § { total: number, rules_total: number },  // OpenShift SDN
    egress_firewalls:        § { total: number, rules_total: number }   // OVN-Kubernetes
  },

  storage_classes: § [                   // sorted by name
    { name: string,
      provisioner: string,
      reclaim_policy: string | null,
      volume_binding_mode: string | null,
      allow_volume_expansion: boolean,
      is_default: boolean,
      parameter_keys: string[] }         // keys only; values never collected
  ],

  nodes: § [
    { id: string,                        // "node-0"...; hostnames anonymised
      roles: string[],                   // e.g. ["master"], ["worker"]
      architecture: string,
      os_image: string,
      kernel_version: string,
      kubelet_version: string,
      container_runtime: string,         // e.g. "cri-o://1.29.5"
      capacity:    { cpu: string, memory: string, pods: string },
      allocatable: { cpu: string, memory: string },
      instance_type: string | null,      // node.kubernetes.io/instance-type label
      zone:   string | null,             // topology.kubernetes.io/zone
      region: string | null }
  ],

  topology: § {                          // derived from the node list
    total_nodes: number,
    control_plane_count: number,         // nodes with master/control-plane role
    infra_count: number,                 // nodes with infra role
    worker_count: number,                // nodes with worker role (incl. shared)
    dedicated_worker_count: number,      // worker nodes that are neither cp nor infra
    ha_classification:
      "single-node"                      // 1 node total (SNO / CRC)
      | "single-control-plane"           // 1 cp node + additional nodes
      | "compact"                        // exactly 3 nodes, all control-plane
      | "standard"                       // >=3 cp + >=1 dedicated worker
      | "other",
    control_plane_schedulable: boolean,  // any cp node lacking a master/
                                         // control-plane NoSchedule taint
    infra_separated_from_workers: boolean,
    infra_nodes_tainted: boolean | null, // null when no infra nodes; true when
                                         // ALL infra nodes carry an infra taint
    zone_spread: {
      distinct_zone_count: number,       // "unlabeled" counts as one zone
      nodes_per_zone: { [zone: string]: number }
    },
    distinct_region_count: number
  },

  quotas: {
    resource_quotas: § {
      total: number,
      namespaces_with_quotas: number,
      distinct_specs: [
        { spec: { hard: object,                  // .spec.hard resource limits
                  scopes: string[],              // standard quota scope enums
                  has_scope_selector: boolean }, // selector contents (may name
                                                 // custom PriorityClasses) omitted
          applied_count: number } ]
    },
    limit_ranges: § {
      total: number,
      distinct_specs: [ { spec: object, applied_count: number } ]
    },
    cluster_resource_quotas: § {
      total: number,
      distinct_specs: [ { spec: object,          // .spec.quota only (selector omitted)
                          applied_count: number } ]
    }
  },

  environment: {
    fips:  § { fips_enabled: boolean },          // any MachineConfig with .spec.fips
    proxy: § {
      http_proxy_configured:  boolean,           // URLs never collected
      https_proxy_configured: boolean,
      no_proxy_entry_count:   number,
      trusted_ca_configured:  boolean
    },
    image_config: § {
      allowed_registries_count:  number,         // registry names never collected
      blocked_registries_count:  number,
      insecure_registries_count: number,
      additional_trusted_ca:     boolean
    },
    image_content_source_policies: § { count: number },   // legacy mirrors (ICSP)
    image_digest_mirror_sets:      § { count: number },   // IDMS
    image_tag_mirror_sets:         § { count: number },   // ITMS
    operator_hub: § { default_sources_disabled: boolean }
  }
}
```

## Interpreting gaps for the sandbox build

| Gap (`status != ok`) | Fallback for the replica |
|---|---|
| `environment.fips` forbidden | Ask verbally: "FIPS mode enabled?" (yes/no) |
| `security.scc_usage` forbidden | Assume workloads run under `restricted-v2` |
| `operators.*` forbidden | Ask for the operator list from the OperatorHub UI |
| any `*.egress_*` api_not_found | Expected; only one of SDN/OVN exists per cluster |
| `quotas.cluster_resource_quotas` api_not_found | Not an OpenShift cluster / API disabled |

## Air-gap / disconnected heuristic

Treat the cluster as disconnected when
`environment.operator_hub.default_sources_disabled == true` and
(`image_content_source_policies.count + image_digest_mirror_sets.count > 0`).
`proxy.*_configured == true` with default sources enabled instead indicates a
proxied (not air-gapped) install.
