# /phone-build

Build a verified native Android package for private phone testing, deliver it to authorized testers when requested, and report the remaining physical smoke checks.

## Arguments

- `$ARGUMENTS` — optional commit/ref and delivery request; resolve the configured source ref when omitted.
- `--prepare` — build and verify only; never upload or notify.
- Without `--prepare`, a request to send/deliver/test on the phone includes private distribution to the previously authorized target and recipients. A build-only invocation does not.

## Project contract

Read the project instructions and these installed customizations before executing:

- Source and helper: {{CUSTOMIZE: Source ref policy and existing project build/test helper commands; helper must accept an immutable commit and external output directory and return artifact/provenance evidence.}}
- Distribution: {{CUSTOMIZE: Existing private-distribution helper and service, private configuration lookup for authorized app/project target and tester recipients, and commands to inspect release/notification state without exposing identities or credentials.}}
- Artifact evidence: {{CUSTOMIZE: Artifact type, package ID, version/buildVersion, signing identity verification, checksum/provenance manifest and gate evidence paths; signing and monotonic buildVersion allocation belong to the project helper.}}
- Phone QA: {{CUSTOMIZE: Automated smoke command, physical device prerequisites, tester install/checklist and evidence source; preserve any existing user hold on physical tests.}}
- Storage: {{CUSTOMIZE: Absolute private output location outside every repo working tree for packages, logs and manifests; private credential/config sources, retention and cleanup policy.}}

Reuse the configured helpers; do not reproduce build, signing, version allocation or distribution logic in this skill. If their required contract is missing, report the exact missing prerequisite and complete independent preparation only.

## Execute

1. Resolve the requested source to a full immutable commit SHA; record whether it matches the latest fetched configured source ref. Never call an unfetched or older commit “latest.”
2. Use a clean isolated checkout of that SHA, respecting worktree and branch rules; reject dirty source rather than silently including or discarding changes. Keep durable output files outside every repo working tree; use the helper's external build/cache paths where supported.
3. Run the configured build/test helper and required gates against that exact commit. Record commands, exit results and evidence. A previous green run counts only when tied to the same source and required configuration.
4. Verify the resulting artifact exists, compute its checksum, and inspect package ID, version/buildVersion and signing identity through the helper. Require consistent signing and a monotonic buildVersion from the project helper before distribution; never invent or race an allocation.
5. Record a private manifest linking commit, artifact checksum, signing/version metadata, gates and automated smoke results. Do not publish a failed or unverified artifact; report the failing prerequisite.
6. For `--prepare` or build-only intent, stop distribution here and report the verified package and remaining phone checks.
7. For delivery intent, use the existing authorized private target and recipient configuration without asking again. If either is absent or ambiguous, prepare the artifact, then obtain explicit target/recipient confirmation before uploading or notifying. Never broaden recipients from discovery results.
8. Upload the exact verified artifact through the project distribution helper, with concise release notes identifying the commit and tested scope. Verify the returned release refers to the expected app, version and artifact; retain the release reference privately.
9. Request the configured tester notification and verify the service response. Report the install link privately when available; mark missing notification evidence as unverified. After an ambiguous upload or notification failure, inspect existing release state before retrying; stop after one diagnosed retry and report the remaining prerequisite.
10. Run available automated smoke checks, then track the physical phone checklist against this same build. Preserve existing physical-test holds; ask the tester to install/open it only when that step is authorized and required. Finish available checks while a physical prerequisite is pending.

## Boundaries and evidence

- Never autonomously install on a phone or publish to Google Play; those are separate explicitly authorized actions.
- Never create a service project, account, billing change, credential or permission scope without specific authorization. Existing distribution authorization does not grant provisioning authority.
- Keep tester identities, credentials and private install URLs out of committed files and public reports; read them from the configured private source and avoid printing credential-bearing command output.
- Distinguish built, gates passed, uploaded, notification accepted, downloaded, installed and physical smoke passed; claim each only with direct evidence. A service accepting a notification does not prove receipt, download or installation.
- Emulator/automated results do not prove physical-device behavior. Report pending phone checks and the person/device prerequisite without declaring the package fully smoke-tested.

## Report

Lead with the verified outcome and private artifact/install link when available. Include full commit SHA, artifact checksum, version/buildVersion, signing check, gate results, distribution/notification evidence and remaining physical checks. Identify whether the delivered build is current at the recorded fetch time.

End with `In effect:` stating what testers can use now and whether it was observed working on a physical phone, then the four-slot `**Status:**` block: ✅ completed, 🔄 every in-flight task enumerated (or `none`), ⛔ blocked prerequisite (or `none`), 🔶 DECISION pending choice (or `none`). Follow with `**Next:** <state> — <one task and executor>`; use RUNNING for continuing work, BLOCKED for prerequisites/decisions, IDLE when nothing waits, or FAILED for a stopped job/limit.

## Customization Points

- Resolve helper commands from the repository; install no unrelated skills or provider tools implicitly.
- Keep public customizations generic; private target and recipient values stay in private configuration.
- Define observable gates and phone checklist for the app's critical workflows.
- Record output retention and existing authorization/holds so later invocations preserve them.
