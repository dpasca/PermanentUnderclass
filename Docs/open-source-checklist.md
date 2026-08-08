# Open-source publication checklist

## Repository-history decision

Keep the existing repository and history. The readiness audit covered all
commits reachable from `master` and found no committed credentials, private
transcripts, recordings, reference documents, home-directory paths, or deleted
private payloads. A full-history Gitleaks scan also reported no findings.

Creating a history-free repository would therefore discard useful development
context without addressing an identified secret. The existing history does
expose ordinary public Git metadata: the maintainer's commit name and email,
timestamps, earlier `MeetingCopilot` path names, and content-provenance metadata
on the icon concept images. None is treated as a blocker for this project.

Re-run the history scan immediately before changing visibility in case private
commits have been added since this audit.

## Before changing visibility

- Merge the readiness changes only after reviewing the synthetic screenshots
  and contribution/security wording.
- Rename the private GitHub repository from `PermamentUnderclass` to
  `PermanentUnderclass`; keep the existing history and `master` branch.
- Run `swift test`, build an ad hoc app bundle, and verify the bundled project
  license plus all third-party notices.
- Run Gitleaks over the complete Git history and OSV-Scanner against
  `Package.resolved`.
- Configure the five Apple signing/notarization secrets documented in
  `Docs/release-engineering.md`, using the same names and formats as Little
  Control Room.
- Confirm that the repository description, topics, and social preview describe
  the Apple-silicon-only release and do not invite external contributions.
- Keep the default branch named `master` unless a rename is deliberately
  requested and migration work is planned.

## GitHub settings to enable when public

- Dependency graph, Dependabot alerts, and Dependabot security updates.
- Secret scanning and push protection.
- Private vulnerability reporting.
- A branch ruleset requiring CI, secret scanning, and dependency checks before
  merges to `master`.
- Read-only default workflow permissions, with write access granted only to the
  release and security workflows that need it.

Dependency review and SARIF upload are intentionally skipped while the
repository is private because those GitHub security surfaces may require a paid
private-repository entitlement. OSV-Scanner still runs and retains its report as
an Actions artifact; both integrations activate automatically after the
repository becomes public.

## Immediately after publication

- Confirm all scheduled and pull-request workflows can run in the public repo.
- Confirm the README renders all three screenshots and every documentation link.
- Publish the first notarized Apple silicon archive only after the tag workflow
  succeeds from signing through Gatekeeper verification.
- Open a synthetic test issue and a private vulnerability draft, then remove
  them, to verify the reporting paths without using real user data.
- Re-check the public file tree from a signed-out browser.
