---
title: "Fit an NSCollectionViewFlowLayout's item size before the layout pass, not inside prepare()"
date: 2026-11-01
category: developer-experience
module: MCApp/GalleryCollectionView
problem_type: developer_experience
component: tooling
severity: medium
applies_when:
  - "A flow-layout subclass sets itemSize or sectionInset from the view's width"
  - "The width changes after the first pass, for example when a vertical scroller appears for a full gallery"
symptoms:
  - "The gallery shows one centred column of the old tile size in a panel that fits two"
  - "A log of the layout's itemSize shows the new size while every cell frame still has the old one"
tags: [appkit, nscollectionview, layout, v04]
---

# Fit an NSCollectionViewFlowLayout's item size before the layout pass, not inside prepare()

## Problem

Audit finding V04: after launch the gallery showed one column in the 260 pt panel instead of two. It only happened with a gallery taller than its panel (twelve images; with six it never did), because the vertical scroller appears and narrows the clip from 260 to 243 pt.

## What was wrong

`GalleryLayout.prepare()` called `fit(width:)`, which writes `itemSize` and `sectionInset`. At 260 pt the first pass fitted 114 pt tiles, two columns. At 243 pt the second pass wrote 105.5 pt in `prepare()`, but the flow layout produced attributes from the previous 114 pt size: the log said `itemSize = 105.5` and every cell frame stayed 114 pt, which fits one column at 243 pt. The first theory (a `setFrameSize` that never invalidates the layout, and a width-only bounds check) was wrong: adding an invalidation and reading the clip width once in `prepare()` still left one column on three of three launches.

## Fix

`GalleryCollectionView.layout()` calls `GalleryLayout.fit(width:)` with the clip width before `super.layout()`, so the flow layout reads the sizes at the start of the pass. `prepare()` and the bounds-change override are gone. When the scroller narrows the clip during a pass, `layout()` runs again and fits to the new width.

## How it was found

Temporary logging (a file write from `prepare()` and `layout()`, removed afterwards) of the clip, frame and bounds width, `itemSize` and the first cell frames per pass. A headless AppKit repro (two attempts, scroll view sized after first layout, legacy scroller) did not fail on the broken code; the live relaunch check was the bar.

## Prevention

- Set a flow layout's item and inset sizes from `layout()` or the delegate, never from `prepare()`.
- Check the grid with a gallery taller than its panel. A six-image home misses this class of bug.
