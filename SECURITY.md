# Security and privacy reports

Do not put suspected vulnerabilities, credentials, kubeconfigs, cluster output,
identities or raw diagnostics in a public issue or PR. If GitHub private
vulnerability reporting is enabled, use **Security → Report a vulnerability**.
Otherwise contact a maintainer through an established private channel before
sharing sensitive detail. No response-time SLA is promised here.

Provide the collector revision, affected code path and a synthetic reproducer.
Describe the exposed field category without including its real value.

Collection is read-only but still requires an explicitly approved target and
account. Reading cluster configuration can be sensitive. Review allowed output
fields before disclosure, including retained platform names, labels and CIDRs.
Fixed diagnostics reduce accidental disclosure; they do not certify compliance.

Do not run live scanning or change permissions to validate a report without
separate authority. See docs/READINESS.md for the offline verification boundary.
