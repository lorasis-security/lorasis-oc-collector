# Collector contributor guidance

This is a standalone, read-only OpenShift configuration-shape collector.
Read README.md and SCHEMA.md before changing collection or output.

- Use Factory Spec for substantial work and retain durable designs for privacy
  or schema changes. Small, clear fixes need no duplicate planning ceremony.
- Start from verified `dev`; feature PRs target `dev`. Preserve existing work,
  published history, the historical example output and the license.
- Action-specific approval rules apply regardless of the Git client used.
  Source work does not authorize pushes, merges, deployments or cluster access.
- Material changes require independent read-only review and relevant checks.
  Every merge requires human approval. Never substitute a different model or
  provider for an explicitly assigned one.
- Run `make setup` then `make verify` for offline development checks. Tests use
  synthetic data and a fake CLI, not an installed `oc` or `kubectl` context.
- Never run the collector against a cluster without exact target authority,
  including for seemingly harmless discovery or readiness testing.
- Keep allowed API operations read-only. Preserve status gaps, schema
  compatibility, field minimization and fixed diagnostic messages.
- Never put customer output, kubeconfigs, credentials, identities or raw
  diagnostics in prompts, commits, public issues, CI logs or artifacts.
- Do not regenerate `example-output.json` as a fixture. It is historical live
  output, not a synthetic test dataset.
- Do not enable paid services, change global clients or infer deployment
  permission from a successful source check.
