# Contributing

Read AGENTS.md, README.md and SCHEMA.md. Start a feature branch from verified
`dev` and open a PR against `dev`; do not rewrite published history.

Run `make setup` then `make verify`. Report the exact candidate, commands and
results. Skipped or unavailable live acceptance is not a pass. Material changes
need independent review and relevant CI; every merge needs human approval.
Changes to collection fields or diagnostics need a documented privacy review and
schema compatibility decision.

Use synthetic inputs. Never attach cluster output, kubeconfigs, identities or
raw diagnostic dumps. The committed historical example is not a fixture to
regenerate. Refer to an existing engineering ticket where applicable rather than
creating duplicate internal work in public issues.

The optional `.pre-commit-config.yaml` uses installed local tools after setup;
it does not install hooks or alter an existing hook configuration automatically.
Binary pin updates require verified official release hashes and tool checks.
Wait seven days for ordinary updates, but handle security fixes promptly.
