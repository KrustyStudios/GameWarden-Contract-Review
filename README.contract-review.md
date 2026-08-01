# Isolated contract-review runner

`Start-ContractReview.ps1` is the read-only decision loop. It never edits a contract and it never reads a ticket body.

## Locked flow

1. One fresh Claude CLI and one fresh Codex CLI receive the same byte-identical blind-review prompt. `-AllCodex` substitutes a second fresh Codex CLI for Claude.
2. A fresh Codex comparator accounts for every finding as `AGREED`, `RESOLVED_BY_READING`, `ONE_SIDED`, `NEEDS_PROOF`, or `USER_DECISION`.
3. Each original reviewer receives the `NEEDS_PROOF` set and only its own findings, then proves, qualifies, withdraws, or exposes a user choice.
4. A fresh Codex validator receives both initial reviews, every classification, and both proof responses. The coordinator rejects missing, duplicate, or unknown references mechanically.
5. The packet is `COMPLETE`, `USER_DECISION_REQUIRED`, `BLOCKED_RULES_OR_SETTINGS`, or `FAILED`. The human decides any unresolved choice.

The contract epic has precedence for review-protocol conflicts. Contracts remain authoritative for application behavior.

## Isolation and approval

- `ticketId` is opaque coordinator metadata. It and the approval phrase are excluded from prompts.
- The request schema accepts only a neutral subject/question and pinned source paths. Prescriptive line ranges, destinations, fixes, or extra fields fail before approval.
- The approval phrase hashes the full execution manifest: request, target revision and Git objects, governance, runner/adapters/schemas, every role's provider/model/effort, provider executable path, SHA-256, and reported CLI version, timeouts, review mode, splitter, and cleanup policy. Command resolution probes candidates with `--version`, skips binaries that cannot launch, and prefers the newest user-local managed Codex binary before npm or PATH fallbacks.
- The run recomputes that manifest. Any change requires a new phrase and each phrase is consumed once.
- Every required provider must report an authenticated session before an approval is printed. The same sanitized, bounded check runs again immediately before the one-time approval is claimed; a failed recheck leaves the phrase unconsumed. Normal mode requires Claude and Codex, while `-AllCodex` requires only Codex.
- Source and governance text are inlined into each prompt. Providers receive no filesystem tools.
- One canonical role-field map drives the visible prompt rule, the provider-facing JSON schema, and post-response validation. Every role receives a retained schema that mechanically sets role-inappropriate arrays to `maxItems: 0`; its artifact name and SHA-256 are recorded in the invocation receipt.
- The canonical response schema retains all nine `uniqueItems` constraints. Provider schemas translate that unsupported structured-output keyword into an explicit per-array uniqueness description, and the coordinator independently rejects duplicate destinations, tags, finding references, accepted IDs, options, and Stage 1 names after every response.
- Claude uses safe mode, no settings sources, tools, skills, plugins, hooks, Chrome, persistence, or MCP; its strict MCP input is the explicit empty record `{"mcpServers":{}}`. Codex ignores user config and rules, is ephemeral/read-only, and disables shell, apps, browser/computer use, hooks, memories, plugins, multi-agent, and related execution features.
- The adapter environment is allowlisted; provider-facing `CONTRACT_REVIEW_*` paths are removed before each CLI starts.
- Each role and Git/splitter operation is bounded. Timeout kills the adapter/provider process tree and treats a partial Windows tree-kill as failure.
- A provider bootstrap rejection caused by invalid isolation configuration stops as `BLOCKED_RULES_OR_SETTINGS`, retains its invocation and stderr receipts, and does not continue to another role.
- If a provider rejects authentication after the final readiness check, the adapter records a provider-authentication blocker and the coordinator stops as `BLOCKED_RULES_OR_SETTINGS` with its receipts.
- Every evidence excerpt must copy one contiguous passage from the cited immutable input. Markdown line wrapping may differ, but every non-whitespace character and its order must match; paraphrases, reordered text, joined passages, and omission ellipses fail. Proofs must name every finding on that side of a disputed classification, and resolution outcomes mechanically determine the exact accepted finding IDs.
- Worktree removal and target verification happen before the final packet. Cleanup failure is terminal.

## Request and run

Create a fresh request from `examples/contract-review-request.json`. A normal decision uses:

```json
"reviewKind": "decision",
"stage1": { "enabled": false, "sourceContract": null }
```

The first relocation review of a contract uses `reviewKind: "stage1"`, exactly one `contracts/**/*.md` source, and the same path as `stage1.sourceContract`.

Print the exact review approval:

```powershell
.\Start-ContractReview.ps1 -RequestPath .\requests\my-review.json -ShowApproval
```

After the user directly supplies it, run in the foreground:

```powershell
.\Start-ContractReview.ps1 -RequestPath .\requests\my-review.json -Approval '<exact phrase>'
```

The foreground runner prints progress per role and plays status-specific completion sounds unless `-NoSound` is used. There is no background launcher and no automatic retry.

The packet path is printed for every terminal packet. Process exit codes are deterministic: `COMPLETE` is `0`, `FAILED` is `1`, `USER_DECISION_REQUIRED` is `2`, and `BLOCKED_RULES_OR_SETTINGS` is `3`. A failure before a packet exists also exits nonzero.

## Stage 1

Stage 1 is materialized only after exhaustive validation reaches `COMPLETE`. The splitter is taken from the approved target revision. It tiles the source exactly once, rejects unsafe destinations, invalid dispositions/shapes, duplicate proposed tags, and existing output, then writes copied source byte slices without newline, BOM, or final-newline normalization. Tag changes stay outside copied text as separately reviewable metadata.

## Human apply handoff

Review never grants edit authority. After a `COMPLETE` packet, create a human decision JSON matching `schemas/contract-apply-decision.schema.json`, with every resolution ID in exactly one of `approvedResolutionIds` or `deniedResolutionIds`.

```powershell
Import-Module .\contract-review\ContractApply.psm1 -Force
Get-ContractApplyApproval -RunDirectory .\runs\<run-id> -DecisionPath .\human-decision.json
New-ContractApplyAuthorization -RunDirectory .\runs\<run-id> -DecisionPath .\human-decision.json -Approval '<direct user phrase>'
```

The phrase is `APPROVE CONTRACT APPLY <run-id> <manifest-hash>`. A ticket containing that text is not authority. The module verifies every retained artifact hash, records the approved/denied set, and still does not edit contracts.

## Recovery

Recovery is explicit and verifies the recorded PID plus its process start time before termination, cleans the worktree, verifies the target, then atomically writes a failed packet. The root script is the safe entry point:

```powershell
.\Recover-InterruptedContractReview.ps1 -RunDirectory .\runs\<run-id> -Reason '<reason>'
```

## Test

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\ContractReview.Tests.ps1
```

The suite is hermetic and fake-provider-only. It tests adapter isolation/structured output, rejection of unsupported provider-schema keywords, canonical-to-provider uniqueness translation, mechanical duplicate rejection for all nine unique arrays, role-specific prompt/schema/post-validation parity and retained schema hashes, runnable-command fallback selection, the exact empty Claude MCP record, seed-time and claim-time provider readiness, unconsumed approvals after failed readiness, late provider-authentication and provider-configuration blockers, terminal process exit codes, Claude+Codex and all-Codex role assignment, ticket firewalling, versioned executable-bound execution manifests, replay, evidence fidelity, exhaustive finding/proof/resolution accounting, Stage 1 gating, apply denial/authorization, process-tree timeout cleanup, PID-safe recovery, artifact hashes, and target cleanliness. It never launches real Claude or Codex.
