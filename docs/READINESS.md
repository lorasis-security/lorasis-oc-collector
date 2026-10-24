# Offline quality and privacy boundary

## Diagnostic hardening design

The original regular expressions removed quoted users, URLs and IPv4 addresses,
but arbitrary CLI/jq diagnostics can contain unquoted identities, bare hostnames,
IPv6 addresses or identifiers cut off before a closing quote. Truncation before
redaction cannot establish that a message is safe to share.

All collection and transformation errors therefore use fixed messages. Preserve
`forbidden`, `api_not_found` and `error` as distinct gap states, with `data: null`.
Do not echo the raw diagnostic to stdout, stderr, CI artifacts or a new log.
Operators can investigate the relevant CLI operation locally under their own
target authority. This deliberately trades embedded diagnostic detail for safer
shareable output; it is not a new permission to run that operation.

Schema 1.1.1 changes error-message content only, not field names or types.
Successful field projections remain unchanged. Platform configuration names,
labels and CIDRs are intentionally retained and may themselves be identifying.
Human output review remains mandatory; this is not an anonymization guarantee or
privacy-compliance certification. The historical example is unchanged.

## Acceptance

`make verify` runs shell syntax, ShellCheck, Python syntax and unittest checks.
The actual collector runs against a synthetic CLI on an allowlisted PATH with a
temporary HOME and nonexistent kubeconfig. Tests verify fixed errors, expected
gap distinctions, projection failures, selected identifier minimization,
kubectl fallback, read-only command verbs, cleanup and schema guidance.
No real client, cluster context, historical output or network is used by tests.

`make setup` is the separate networked dependency step. It downloads only the
official ShellCheck and jq release assets pinned in `tools/tools.lock.json`,
checks SHA-256 before use and installs within ignored `.tools/`. It never installs
or invokes a cluster client. CI does not upload that cache or collector output.

## Remaining debt

Maintainers own these follow-ups; source checks do not close them:

- Live operator acceptance on an explicitly approved target, including multi-node
  and FIPS-enabled clusters. Historical README results are not this candidate's
  installed acceptance.
- Bounded cluster request timeouts and cancellation behavior, with compatible
  oc/kubectl semantics and operator review.
- More successful-section coverage and measured Bash coverage. No coverage
  percentage or threshold is currently claimed.
- Shell/Python formatting, typing, duplication/size gates and scanner automation.
  Syntax checking is not Python type checking.
- Broader platform development-tool setup. Locked downloads target Linux x86_64;
  other systems supply their own compatible tools using documented overrides.
- Hosted dev check enforcement after successful CI and administrator access.
  Instructions and CODEOWNERS alone do not enforce review.
- Automated checks for official binary pin updates. For ordinary dependency
  updates, allow at least seven days after release; do not delay security fixes.
  The Dependabot configuration targets dev but is only activated when present
  on GitHub's default branch, currently main. No promotion or default-branch
  change is authorized by this readiness work. This configuration does not
  produce automatic security-update PRs for dev; maintainers must handle those
  fixes explicitly.

No deployment pipeline, telemetry, live scanning or paid review service is added
for an audit score.
