---
title: "Attach acceptance screenshots to a PR with gh pr comment --attach"
date: 2026-11-04
category: developer-experience
module: docs/design-audit
problem_type: developer_experience
component: development_workflow
severity: low
applies_when:
  - "A design-audit spec's acceptance list says captures are attached to the PR"
  - "A PR on this private repo needs screenshots as proof of a UI change"
symptoms:
  - "Resolution sections record that captures were taken but not attached to the PR"
  - "An agent concludes it cannot upload images to a pull request from the command line"
tags: [pull-request, screenshots, gh-cli, design-audit, capture-kit, private-repo]
---

# Attach acceptance screenshots to a PR with gh pr comment --attach

## Context

Most design-audit specs end with a check like "Captures `S07_sheet_small_light.png` and `S07_panel_small_light.png` are attached to the PR". S01, S02, S03, S06, S07, I02, I03, I05, I06, I09, I10, V01 and V06 each carry one (I04 asks for it conditionally). The capture kit writes the images to `/tmp/mc-audit-shots`, which no reviewer can see.

Earlier Resolution sections show the check being skipped: S02, S03 and S04 each say their captures were not attached to the PR. S07 started the same way, on the belief that `gh` cannot upload an image. It can. The repo is private, so there is no public image host to link to.

## Guidance

Post the captures as a PR comment with `gh pr comment --attach`. Its help says an image reference in the body that matches an attached file is rewritten to the uploaded asset, and an attached file the body does not reference is appended:

```bash
cd /tmp/mc-audit-shots
gh pr comment 39 --body-file /tmp/pr-captures.md \
  --attach './S07_panel_small_light.png#Panel' \
  --attach './S07_sheet_small_light.png#Sheet opening on Civitai'
```

The body file references each image by its relative path, as a standard markdown image with the same `./S07_…png` path. The text after `#` in `--attach` is the alt text. To fix a comment you already posted, use `--edit-last` with the same flags. Run `gh pr comment --help` first: the flag is in `gh` 2.102.0 here, and an older `gh` may not have it.

Check the result without a browser. The comment's rendered HTML shows whether GitHub accepted each image:

```bash
gh api repos/<owner>/<repo>/issues/comments/<id> -H "Accept: application/vnd.github.html+json" --jq '.body_html'
```

In the rendered HTML each image links to a `private-user-images.githubusercontent.com` URL, and the plain `.body` holds `https://github.com/user-attachments/assets/...` links. Opening them in a browser was not part of this check.

## Why This Matters

A spec's capture check is the reviewer's only evidence for a visual claim, and the GUI smoke does not cover most of these screens. Without the attachment, a PR says "captured" and shows nothing.

Two other routes exist and were not kept:

- A throwaway orphan branch holding the PNGs, linked as `blob/<branch>/<file>?raw=true`. S07 posted it this way first, without checking that it rendered, then replaced it. Deleting the branch would have broken the images in the comment, so it needs cleanup that `--attach` does not.
- Committing the PNGs to `docs/design-audit/screens/`, as PR #28 did for S06. That keeps per-PR proof in the tree; a PR comment does not.

## When to Apply

- Any spec check or PR checklist that asks for captures to be attached.
- A UI change without such a check, when a reviewer would otherwise judge it from a description.

## Examples

S07's captures went up in one comment on PR #39: the panel with its single Add LoRA… button, the sheet opening on Civitai for a model with an empty shelf, and the sheet opening on Your LoRAs after a LoRA was added.
