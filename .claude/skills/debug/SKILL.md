---
type: reference
last_verified: 2026-05-20
owner: harness-installer
---

# Debug Skill

Systematic debugging protocol. Follow this exactly — do not skip steps.

## Step 1: Reproduce

Before doing anything else: can you reproduce the problem?
- Run the exact command/scenario that triggered it.
- If you cannot reproduce: STOP and say so. Do not guess at fixes for unreproducible problems.

## Step 2: Read the execution path

Identify every file involved in the failing path. Read them all:
- Entry point → called functions → dependencies → config files → env vars

Note what each file does and what it expects.

## Step 3: Form one hypothesis

State it explicitly: "I believe the problem is X because Y."

Do not form multiple hypotheses yet. Test this one first.

**A symptom that is consistent with a cause is not evidence of that cause.** Before declaring a root cause, find direct evidence — the actual error message, the actual output, the actual state. If you cannot read the evidence (log inaccessible, output missing), say so explicitly and get it before concluding. "The log would show X" is speculation, not diagnosis.

## Step 4: Test the hypothesis

Add a log line or print statement at the point you expect the failure. Run again. Read the output.

Does the evidence support the hypothesis?
- Yes → proceed to fix
- No → state a new hypothesis, go to step 3

## Step 5: Fix minimally

Make the smallest possible change that fixes the root cause. Do not fix adjacent issues in the same commit.

## Step 6: Verify

Run the reproduction case again. Confirm it passes. Run any existing tests.

## Step 7: Document

Write to `.beads/failures.jsonl`. Include the exact root cause and lesson (not "fixed the bug" — the lesson that would prevent it next time).

If the failure should have an eval, note it in the `lesson` field and create the eval task.
