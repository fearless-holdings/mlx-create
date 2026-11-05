---
description: Commit, push, land and clean up this session's PR(s) against main
argument-hint: "[PR numbers or notes]"
---

Land this session's work end to end. Treat `$ARGUMENTS` as extra notes or an explicit PR list; if it is empty, work out the PRs from the current branch, `gh pr list --head <branch>`, and `gh stack view --json`.

Do not stop between phases to ask for permission for anything this command already covers: committing, pushing, opening or updating the PR, merging, deleting the merged branches, local cleanup, and returning to `main`. Stop only for the safety gates listed in "Stop conditions".

## 0. Preflight

- `git status --short --branch`, `git rev-parse --abbrev-ref HEAD`, `git worktree list`.
- If the working tree is on `main`, there is nothing to ship unless `$ARGUMENTS` names PRs: say so, then do the final `main` sync in phase 6.
- If any change belongs to someone else (a file you did not touch, an unrelated dirty branch), leave it alone and report it.
- Confirm the GitHub account is the one that owns the remote. On "Repository not found" or auth noise, get the token for the remote owner's account rather than switching the active account, and never echo the token.
- If the branch is part of a stack (`gh stack view --json` returns more than one layer, or the branch has a parent), read `.agents/skills/gh-stack/SKILL.md` before touching anything.

## 1. Commit and push every relevant change

- Inspect `git status` and the diff. Everything that belongs to this session's task goes in: source, tests, docs, `AGENTS.md` updates, audit tracker rows, catalog or `engine.lock` changes, and the cleanup of anything the task made obsolete.
- Verify before committing:
  - `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
  - `swift test` (about 40 s; past 2 minutes it is hung: `pkill -f swiftpm-testing-helper; pkill -f swift-test`, then bisect with `--filter`).
  - If Swift files changed, the pre-commit hook does the lint check too. Never use `--no-verify`, never rewrite pushed history, never force-push.
  - If the task changed the engine pin or engine-facing code, `sh scripts/engine-contract/check_lock.sh engine.lock` is part of the evidence, and the engine contract suite must have passed before `engine.lock` moved.
  - If the task touched UI, `scripts/gui-smoke/run_smoke.py` evidence exists (exit 2 is NOT RUN, never a pass).
- Commit in coherent units with the repo's message style, carrying the same trailers the work needs (`Audit: <ID>` for design-audit findings).
- Nothing secret goes in. Confirm `.env` is untracked and unstaged before every commit.
- Push the branch (`git push -u origin <branch>`); if the branch is stacked, push layers with `gh stack submit --auto` instead of one push per layer.

## 2. Get a PR against `main` that is current and green

- If no PR exists, open one against `main`: real description of the change, linked decision IDs (`D*`), `Audit: <ID>` when applicable, and the verification evidence (tests run, smoke output, GUI smoke path).
- If a PR exists, make sure its body matches the final code, then push any remaining commits.
- Check the PR is mergeable: `gh pr view <N> --json state,mergeable,mergeStateStatus,statusCheckRollup,reviewDecision,baseRefName`.
  - `BEHIND` → update the branch (`gh pr update-branch <N>`, or rebase the stack with `gh stack submit --auto`), then re-check.
  - Failing checks → fix the cause, commit, push, wait for the new run. Never merge red checks, never bypass a required review, never disable a workflow to land.
  - Unresolved review comments → resolve them with a real fix and reply in the thread.
- Run the merge-convention check: `git log --merges --oneline -5`. Use the repo's existing style (squash for ordinary single-concern PRs unless history clearly uses merge commits; stacked layers merge bottom-up so the stack stays linear).
- Repeat until every PR in scope reports `mergeable: MERGEABLE` with a passing rollup and a satisfied review requirement.

## 3. Merge

- Merge in dependency order: stack layers bottom-up, otherwise oldest first.
- `gh pr merge <N> --squash --delete-branch` (or `--merge` per the convention from phase 2). For a stack, `gh stack merge` / the workflow in the gh-stack skill, then confirm each layer's base now points at `main`'s new tip.
- After each merge, confirm `state: MERGED` and record the merge commit. Never merge the next layer until the previous one has landed.

## 4. Delete the branches

- Remote: `gh pr merge --delete-branch` already removes the head branch; if it survived, `git push origin --delete <branch>`.
- Local: switch off the branch first, then `git branch -d <branch>` (never `-D`; a branch that refuses to delete is unmerged work — stop and report instead of forcing it). For a stack, delete every layer's local and remote branch after its PR is merged.
- Remove worktrees created for these branches: `git worktree remove <path>` for each entry in `git worktree list` that belongs to a merged branch, and delete its directory if it survived. Leave unrelated worktrees alone.

## 5. Local cleanup

- Prune stale merged branches that are already gone from the remote: `git fetch --prune`, then `git branch -vv | grep ': gone]'` and delete only branches whose work is merged into `main` or that the remote has dropped.
- Clean build artifacts: `build/` (and its `gui-smoke` evidence only after its path is quoted in the PR), `.build`/`DerivedData` leftovers, generated `MLXCreate.xcodeproj` if it is untracked and the task does not need it. Do not touch: the `MLX-Serve.app` engine build, downloaded weights under `Models/`, the dev catalog key, or anything outside this repo.
- Check for leaked engine processes: `pgrep -fl mlx-serve`. Kill one only when its argv names this session's throwaway home; never kill by name alone, because another task may be running its own engine.
- Confirm `git status` is clean and `git stash list` has nothing this session dropped.

## 6. Return to `main`

- `git checkout main` (or `git switch main`).
- `git pull --ff-only origin main`. If it fails, `main` diverged locally: stop and report, do not force or reset.
- Delete any remaining local branch from this session, and confirm `git status --short --branch` shows `main` clean at `origin/main`.

## 7. Report

Prove the end state rather than asserting it:

| Item | Evidence |
| --- | --- |
| PR(s) | number, title, merge commit, `state: MERGED` |
| Branches | each local/remote branch and that it is gone (`git ls-remote --heads origin` has no match) |
| Working tree | `git status --short --branch` output |
| `main` | `git rev-parse HEAD` equals `git rev-parse origin/main` |
| Cleanup | branches pruned, worktrees removed, artifacts removed, engines stopped |
| Not done | anything skipped and why |

## Stop conditions

Stop and ask, keeping done work committed and pushed, when any of these is true:

- A merge would land red checks, a missing required review, or a conflicted base you cannot fix.
- Local uncommitted changes belong to another task or another person.
- A branch will not delete without force, meaning it holds unmerged work.
- `main` diverged in a way `--ff-only` refuses.
- The change would require `--no-verify`, a force-push, a history rewrite, or disabling a check.
- The task turns out to need a decision the HLD does not have. Update `docs/HLD.md` first or ask; never let code silently diverge from a `D*` entry.
