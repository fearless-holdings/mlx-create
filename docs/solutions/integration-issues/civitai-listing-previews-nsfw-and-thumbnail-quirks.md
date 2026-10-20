---
title: "Civitai listing previews: huge originals, video URLs, and unreliable NSFW signals"
date: 2026-10-20
category: integration-issues
module: MCModels/Civitai and MCApp/Civitai
problem_type: integration_issue
component: service_layer
symptoms:
  - "Browse thumbnails take seconds to appear and are re-fetched on every scroll or filter change"
  - "Some rows show a plain gray square instead of a preview"
  - "With NSFW off, some rows still have no image at all"
  - "With NSFW on, explicit previews appear unblurred on models Civitai flags nsfw:false"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [civitai, thumbnails, nsfw, asyncimage, cdn, browse]
---

# Civitai listing previews: huge originals, video URLs, and unreliable NSFW signals

## Problem
The Browse Civitai tab (PR #7) took Civitai's listing data at face value. The listing's image URLs, its NSFW flags, and its omission of images turned out to behave differently from what the field names suggest. The result was slow, uncached, sometimes blank thumbnails, and an NSFW blur that missed explicit previews.

## Symptoms
- Thumbnails took a few seconds to appear and again after every scroll or NSFW toggle.
- Some rows stayed gray with no error.
- Some LoRAs had no image with NSFW off.
- A model Civitai flagged `nsfw:false` showed an explicit preview unblurred once Include NSFW was on.

## What Didn't Work
- **`AsyncImage` on the listing URL.** The URL pointed at `original=true`, which is the full original. One file measured **4.2 MB** in a live probe, against about **54 KB** at 128 px. `AsyncImage` also keeps nothing decoded, and files that size do not fit the default URL cache, so every scroll refetched.
- **Treating the gray squares as a fetch bug.** There were two separate causes. Some previews are videos (`.mp4`), which `AsyncImage` cannot decode. The rest had no image to fetch (below). A parallel fetch of 34 rewritten thumbnail URLs all returned `200 image/jpeg`, so the CDN was not at fault.
- **Showing a placeholder and a tooltip telling the user to turn on NSFW.** That described the data wrongly. Once the filter below existed, the row would not be listed at all.
- **Trusting the model-level `nsfw` flag.** An adversarial review probed the Krea 2 top 100 and found 10 models flagged `nsfw:false` whose preview image had level 4 or 8 (for example Famegrid at level 8). Per the reviewer, not independently re-run. (session history)
- **Filtering on the spec's preview URL.** Dropping rows without a downloadable file also dropped LoRAs that have images but no valid file, and broke existing tests. The filter has to look at the images of the version being shown.

## Solution
1. **Rewrite the URL to a CDN transform.** The path segment before the file name takes a transform string. `CivitaiImage.thumbnailURL(_:width:)` replaces it with `anim=false,width=N`, which returns a small still JPEG for both images and videos. It leaves other hosts and URLs with no `=` segment untouched (`Sources/MCModels/Civitai/CivitaiModels.swift:223-236`).
2. **Cache decoded thumbnails in memory.** `CivitaiThumbnailCache` is an `NSCache` with a 64 MB cap, keyed by the rewritten URL, 128 px wide for 64 pt rows (`CivitaiBrowseSupport.swift`, `CivitaiThumbnailCache`). It is memory-only so nothing about what the user browsed reaches disk. Failures are not cached, so a later visit retries. The `CivitaiThumbnail` view reads the cache synchronously first, so a cached image appears on the first frame.
3. **Hide LoRAs with no preview while NSFW is off.** With `nsfw=false` Civitai returns no images for a LoRA whose examples are all NSFW. Such a result is an NSFW LoRA, so `fetchPage` drops it unless Include NSFW is on. It also drops anything the model-level flag marks NSFW (`CivitaiBrowseModel.swift:247-255`).
4. **Pull the next page when filtering empties one,** up to `maxEmptyPageSkips = 5` pages in a row (`CivitaiBrowseModel.swift:258,282`).
5. **Blur by the shown preview's own level.** A row is NSFW when the model flag is set or the displayed image's `nsfwLevel` is above 1, and a missing level counts as NSFW (`previewIsNSFW`, `CivitaiPreviewRule.isNSFW`, `CivitaiBrowseView.swift:7-10`).
6. **Reset the searched marker when the first page is cancelled** (`CivitaiBrowseModel.swift:270`). Otherwise leaving the tab mid-load made the next visit skip the search and show a spinner forever.

## Why This Works
Civitai's listing is a description of a gallery, not of thumbnails. The CDN does the resizing, but only when asked through the path segment. The NSFW state lives in three places that disagree: the model flag, each image's level, and whether images are sent at all. Only the image level is about the thing the user is looking at, so the blur keys off it, and the model flag and image presence are used only for the hide decision.

## Prevention
- Never hand a Civitai image URL to a view without the thumbnail rewrite, and never assume a URL is a still image.
- Decide blur from the shown image's level, not the model flag. `CivitaiBrowseModelTests` has a case with an `nsfw:false` model carrying a level 8 image.
- Treat "no images with NSFW off" as meaningful data. The test `withNSFWOffAResultWithoutImagesIsLeftOutAndAnEmptiedPagePullsTheNext` pins it, and another test pins the 5-page limit.
- When a view-model marks a search as done, a cancelled first load must undo that mark. The test `leavingTheTabBeforeTheFirstPageLandsLetsTheNextVisitSearchAgain` pins it.
- `CivitaiThumbnailURLTests` covers the rewrite, including a second rewrite and non-Civitai hosts.

## Related Issues
- PR #7 (Civitai browse and download). Plan: `docs/plans/2026-10-19-1605-feat-civitai-lora-browse-download-plan.md`; LLD: `docs/lld/loras.md`.
- Still open from the same review: the cache counts JPEG bytes rather than decoded size, and the CDN's 128 px request may come back wider (reported as 320 px, not verified).
