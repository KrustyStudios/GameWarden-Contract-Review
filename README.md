# GameWarden Contract Review

A small, read-only loop for independent contract review:

- one guidance file;
- the target repository's existing AI rules and guardrails;
- one source contract;
- one watcher;
- two blind CLI reviewers;
- one Codex comparator and final validator;
- an isolated destination-review mode for approved Phase 1 staging.

The watcher accepts no ticket and no free-form brief. Both blind reviewers read the same
existing guide, rules, guardrails, and source contract through the same exact full paths.
Only their output directories are separate. Their reports are withheld until both finish
successfully.

## Requirements

- PowerShell 7
- Claude CLI logged in for normal mode
- Codex CLI logged in
- the target repository's approved `tools/ai/split-contract.ps1`

Defaults favor review quality: Claude `opus`, Codex `gpt-5.6-sol`, and Codex reasoning
effort `max`. Use `-AllCodex` to explicitly replace Claude with a second fresh Codex CLI.
There is no automatic fallback or retry.

## Run

First print the approval phrase:

```powershell
./Start-ContractReview.ps1 `
  -RunId steamcmd-stage1-001 `
  -GuidePath <path-to-contract-epic.md> `
  -RulesPath <path-to-AI_RULES.md> `
  -GuardrailsPath <path-to-AI_GUARDRAILS.md> `
  -TargetPath <path-to-source-contract.md> `
  -SplitterPath <path-to-split-contract.ps1> `
  -ShowApproval
```

After the human supplies that exact phrase, run the same command with approval:

```powershell
./Start-ContractReview.ps1 `
  -RunId steamcmd-stage1-001 `
  -GuidePath <path-to-contract-epic.md> `
  -RulesPath <path-to-AI_RULES.md> `
  -GuardrailsPath <path-to-AI_GUARDRAILS.md> `
  -TargetPath <path-to-source-contract.md> `
  -SplitterPath <path-to-split-contract.ps1> `
  -Approval 'APPROVE CONTRACT REVIEW steamcmd-stage1-001 <hash>'
```

The hash binds the exact full paths and bytes of the guide, rules, guardrails, source,
watcher, and splitter, plus the routing mode, models, CLI commands, and timeout. Any change
requires a new phrase. A run ID cannot be reused.

## Destination review

After the source round produces a Phase 1 working file for one destination, print a new
approval phrase with the same watcher:

```powershell
./Start-ContractReview.ps1 `
  -DestinationReview `
  -RunId steamcmd-destination-001 `
  -GuidePath <path-to-contract-epic.md> `
  -RulesPath <path-to-AI_RULES.md> `
  -GuardrailsPath <path-to-AI_GUARDRAILS.md> `
  -OriginalSourcePath <path-to-original-source-contract.md> `
  -IncomingPath <path-to-phase1-working-file.md> `
  -DestinationPath <exact-existing-or-proposed-contract-path> `
  -MaterializerPath ./Materialize-Destination.ps1 `
  -ShowApproval
```

Run the same command with `-Approval '<exact printed phrase>'` after the human supplies
it. Both blind reviewers read the same exact shared paths and reconcile only that one
destination. The final validator returns the epic's ordered `COPY`, `RENAME`, `SPLIT`,
`DELETE`, and `NEW` manifest. The materializer checks complete line coverage first and
then creates `staging/destination.md`; it never creates or edits the final destination.

## What happens

1. Claude and Codex read the same shared inputs and review concurrently and blind. In
   `-AllCodex` mode, two fresh Codex sessions do this instead.
2. A fresh Codex compares both reports, including different finding counts and different
   source splits.
3. Each original reviewer receives only its own report and the comparator's disputed
   claims, then proves or withdraws them.
4. A fresh Codex validates the comparison and proofs.
5. If the result is complete, the watcher extracts the final Stage 1 manifest and calls
   the approved splitter first with `-CheckOnly`, then once to create staging files.

The watcher never edits or copies an input contract. In source mode, the approved splitter
alone copies selected source ranges. In destination mode, the materializer copies unchanged
ranges as raw bytes, changes only an approved tag for `RENAME`, and writes only exact approved
text blocks for `SPLIT` or `NEW`. Applying an approved result remains a separate
human-authorized workflow.

## Output

Each run gets one folder under `runs/` containing the two reviews, comparison, proofs,
final validation, manifest, staging files, splitter logs, and a SHA-256 receipt. Private
output directories are always removed.

If a provider fails, blocks, or times out, the watcher stops the run, terminates the peer
process tree, retains the original stderr and exit code, and does not start the next role.
Inspect the failure, fix its cause, and start a fresh run ID.

## Test

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File ./tests/ContractReview.Tests.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File ./tests/PublicRepository.Tests.ps1
```

Tests use fake CLIs and a fake source splitter. They verify shared exact input paths,
isolated output directories, path-bound approval, verbatim staging, complete destination
coverage, all five destination operations, and retained logs without launching Claude or
Codex.
