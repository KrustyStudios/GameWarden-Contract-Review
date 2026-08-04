# GameWarden Contract Review

A small contract-placement loop:

- two blind CLI reviewers read the same guide, rules, guardrails, original contract, and staged-contract tree;
- a script turns each private placement manifest into one review grouped by destination;
- one Codex comparator compares those two generated reviews;
- disputed placements go back to the original reviewers for proof;
- one Codex validator produces the final private placement manifest;
- the same script creates one final grouped review and adds its rules to the separate staged-contract tree;
- one fresh Codex verifies the staged result against the original and final review.

The original contracts are read-only. The copy script gives each source block a stable ID.
Both blind reviewers receive the same block map and copy those IDs into their private
manifests; no AI counts source lines. Block IDs never appear in retained reviews or staged
contracts. There is no separate per-destination AI round.

## Requirements

- PowerShell 7
- Claude CLI logged in for normal mode
- Codex CLI logged in
- the target repository's approved placement/copy script
- an existing separate directory for staged contracts; it may be empty

Defaults favor review quality: Claude `opus`, Codex `gpt-5.6-sol`, and Codex reasoning
effort `max`. Use `-AllCodex` to explicitly replace Claude with a second fresh Codex CLI.
There is no automatic fallback or retry.

## Stage 1 review

First print the one-time approval phrase:

```powershell
./Start-ContractReview.ps1 `
  -RunId steamcmd-stage1-001 `
  -GuidePath <path-to-contract-epic.md> `
  -RulesPath <path-to-AI_RULES.md> `
  -GuardrailsPath <path-to-AI_GUARDRAILS.md> `
  -TargetPath <path-to-original-contract.md> `
  -StagingRoot <path-to-separate-staged-contract-tree> `
  -SplitterPath <path-to-split-contract.ps1> `
  -ShowApproval
```

After the human supplies that exact phrase, run the same command with:

```powershell
-Approval 'APPROVE CONTRACT REVIEW steamcmd-stage1-001 <hash>'
```

The hash binds the exact paths and bytes of the guide, rules, guardrails, original source,
watcher, and copy script; the script-generated source block map; the complete initial
staged-tree snapshot; and the routing mode, models, CLI commands, and timeout. Any change
requires a new phrase. A run ID cannot be reused.

Each successful run retains:

- `review-a.md` and `review-b.md`, generated mechanically and grouped by destination;
- `comparison.md` and any proof responses;
- `final-review.md`, generated from the validated final placement;
- `staging-verification.md` from a fresh Codex;
- copy-script logs and a SHA-256 receipt.

Private AI manifests and working directories are always removed. The staged contracts
live only under `-StagingRoot` and may be reviewed by the human before Stage 2.
If a source rule already exists there, an `OMIT` placement must name that exact staged
contract and tag; the copy script verifies the survivor and does not duplicate the rule.

## Phase 2 exact copy

After the human approves the complete staged-contract tree, put one row per final contract
between `BEGIN PHASE2 COPY MANIFEST` and `END PHASE2 COPY MANIFEST`:

```text
COPY<TAB><exact-full-staging-path><TAB><contracts/.../NAME_CONTRACT.md><TAB><lowercase-sha256>
```

Print the one-time Phase 2 approval phrase:

```powershell
./Start-ContractReview.ps1 `
  -Phase2 `
  -RunId steamcmd-phase2-001 `
  -GuidePath <path-to-contract-epic.md> `
  -RulesPath <path-to-AI_RULES.md> `
  -GuardrailsPath <path-to-AI_GUARDRAILS.md> `
  -Phase2ManifestPath <path-to-approved-phase2-manifest.md> `
  -OutputRoot <exact-new-contract-tree-path> `
  -CopierPath ./Copy-ApprovedContracts.ps1 `
  -ShowApproval
```

Run the same command with
`-Approval 'APPROVE CONTRACT APPLY steamcmd-phase2-001 <hash>'` after the human supplies
that exact phrase. Phase 2 copies the approved staged files byte for byte into a new tree
and uses a fresh read-only Codex to verify the result. It does not edit the originals.

## Failure behavior

If a provider fails, blocks, or times out, the watcher stops the run, terminates its peer,
retains the original error, and does not start the next role. If final staging verification
blocks, the staged files and evidence are retained for human review; the verifier never
repairs them. Fix the cause and use a fresh run ID.

## Test

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File ./tests/ContractReview.Tests.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File ./tests/PublicRepository.Tests.ps1
```

The tests use fake CLIs and a fake copy script. The target repository's tests separately
exercise its real copy script against exact source bytes, tag changes, splits, coverage,
safe destinations, and staged-tree updates.
