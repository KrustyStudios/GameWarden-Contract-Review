# Isolated contract-review runner

`Start-ContractReview.ps1` is the read-only decision loop. It never edits a contract and it never reads a ticket body.

> **Development status:** Pre-release and fail-closed. Hermetic tests pass, while live-provider validation is still in progress. Review failures retain their receipts and require a fresh request ID; runs are never silently retried.

## Public-repository boundary

This repository contains only the runner, schemas, generic examples, and fake-provider tests. Review requests, prompts, responses, receipts, run directories, target repositories, credentials, provider settings, and local handoff notes are runtime/private data and must not be committed.

Public updates use a clean, allowlisted export based on this repository's `main`. Development-checkout history and internal support files are intentionally not connected or merged into this public history.

## Locked flow

1. One fresh Claude CLI and one fresh Codex CLI receive the same byte-identical blind-review prompt and run concurrently. `-AllCodex` substitutes a second fresh Codex CLI for Claude. Comparison starts only after both succeed.
2. A fresh Codex comparator accounts for every finding as `AGREED`, `RESOLVED_BY_READING`, `RESOLVED_BY_JUDGMENT`, `ONE_SIDED`, `NEEDS_PROOF`, or `USER_DECISION`. Judgment resolution is limited to choosing between otherwise compliant replacement-tag names. Each judgment classification covers exactly one existing tag and must preserve identical disposition, destinations, and source fragments apart from the proposed replacement name; other differences are classified separately.
3. Each original reviewer receives the `NEEDS_PROOF` set and only its own findings, then proves, qualifies, withdraws, or exposes a user choice.
4. A fresh Codex validator receives both initial reviews, every classification, and both proof responses. Reviewer-local finding IDs are qualified as `A:<id>` and `B:<id>` at this boundary, so equal IDs from separate reviewers remain distinct. The coordinator rejects missing, duplicate, or unknown references mechanically.
5. The packet is `COMPLETE`, `USER_DECISION_REQUIRED`, `BLOCKED_RULES_OR_SETTINGS`, or `FAILED`. The human decides any unresolved choice.

The contract epic has precedence for review-protocol conflicts. Contracts remain authoritative for application behavior.

## Isolation and approval

- `ticketId` is opaque coordinator metadata. It and the approval phrase are excluded from prompts.
- The request schema accepts only a neutral subject/question and pinned source paths. Prescriptive line ranges, contract filenames or paths, destinations, fixes, or extra fields fail before approval.
- The approval phrase hashes the full execution manifest: request, target revision and Git objects, governance, runner/adapters/schemas, every role's provider/model/effort, provider executable path and SHA-256, timeouts, review mode, splitter, and cleanup policy.
- The run recomputes that manifest. Any change requires a new phrase and each phrase is consumed once.
- Every required provider must report an authenticated session before an approval is printed. The same sanitized, bounded check runs again immediately before the one-time approval is claimed; a failed recheck leaves the phrase unconsumed. Normal mode requires Claude and Codex, while `-AllCodex` requires only Codex.
- Source and governance text are inlined into each prompt. Every role starts in a fresh empty operating-system temporary directory that is deleted after the invocation.
- One canonical role-field map drives the visible prompt rule, the provider-facing JSON schema, and post-response validation. Every role receives a retained schema that mechanically sets role-inappropriate arrays to `maxItems: 0`; its artifact name and SHA-256 are recorded in the invocation receipt.
- Claude uses safe mode, no settings sources, tools, skills, plugins, hooks, Chrome, persistence, or MCP; its strict MCP input is the explicit empty record `{"mcpServers":{}}`. Codex ignores user config and rules, is ephemeral/read-only, and requests that shell, apps, browser/computer use, hooks, memories, plugins, multi-agent, and related execution features be disabled.
- Before an approval phrase can be printed, the configured Codex transport must pass a real fail-closed isolation preflight. The model is asked to report any callable capability, inherited guidance, workspace access, or unrelated environment access. A claimed configuration is never accepted from flags or adapter metadata alone.
- The current direct Codex CLI transport is usable only if its installed build passes that preflight. Codex CLI documentation exposes controls for user config, exec-policy rules, sandboxing, and individual features, but no documented prompt-only/no-built-in-tools mode. If the preflight detects exposure, the loop stops before approval. Operators must use a supported truly tool-free transport (for example, a separately authorized direct model API adapter that supplies no tools) or wait for a CLI mode that passes; weakening the preflight is not an alternative.
- The adapter environment is allowlisted; provider-facing `CONTRACT_REVIEW_*` paths are removed before each CLI starts.
- Each role and Git/splitter operation is bounded. Timeout kills the adapter/provider process tree and treats a partial Windows tree-kill as failure.
- A provider bootstrap rejection caused by invalid isolation configuration stops as `BLOCKED_RULES_OR_SETTINGS`, retains its invocation and stderr receipts, and does not continue to another role.
- If a provider rejects authentication after the final readiness check, the adapter records a provider-authentication blocker and the coordinator stops as `BLOCKED_RULES_OR_SETTINGS` with its receipts.
- Every evidence excerpt must match one contiguous cited input passage after whitespace-only normalization. All non-whitespace characters and their order must remain unchanged; paraphrases, reordered text, joined passages, and omission ellipses fail. Every proof position requires at least one cited source passage. Proofs must name every finding on that side of a disputed classification, and resolution outcomes mechanically determine the exact reviewer-qualified accepted finding IDs.
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

Stage 1 is materialized only after exhaustive validation reaches `COMPLETE`. Before either reviewer starts, the exact splitter from the approved target revision must pass a check-only compatibility probe covering repository-relative contract paths, untagged sections, separate `MOVE` rename metadata, and multi-destination `SPLIT` metadata.

Each accepted placement records exact destination-specific source fragments, and every final manifest row cites the accepted finding IDs it implements. The coordinator expands those assignments and rejects a mismatched range, destination, or proposed tag. A `SPLIT` duplicates one complete range only when every byte belongs in every destination; destination-specific subranges require separate non-overlapping `MOVE` rows.

The completed manifest passes check-only validation again before materialization. The splitter tiles the source exactly once, rejects unsafe destinations, invalid shapes, duplicate proposed tags, and existing output, and writes each staging file at its repository-relative contract path. Copied source byte slices retain their newline, BOM, and final-newline bytes. Tag changes remain outside copied text as separately reviewable metadata.

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

The suite is hermetic and fake-provider-only. It tests adapter isolation/structured output, isolation-preflight exposure, fresh empty provider working directories, canonical-to-provider schema translation, mechanical uniqueness checks, cross-reviewer ID collisions, role-specific prompt/schema/post-validation parity and retained schema hashes, pinned-splitter compatibility before provider startup, completed-manifest check-only validation, destination-fragment accounting, provider readiness and authentication blockers, concurrent Claude+Codex and all-Codex blind roles, peer cancellation before comparison, ticket firewalling including prescribed contract paths, executable-bound execution manifests, replay, evidence fidelity including mandatory proof citations, exhaustive finding/proof/resolution accounting, Stage 1 gating, apply denial/authorization, process-tree timeout cleanup, exact-PID recovery, artifact hashes, and target cleanliness. It never launches real Claude or Codex.
