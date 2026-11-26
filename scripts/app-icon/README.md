# App icon

Regenerate `App/Assets.xcassets/AppIcon.appiconset/` PNGs:

    swift scripts/app-icon/draw_icon.swift App/Assets.xcassets/AppIcon.appiconset

The script draws the "sun in crop marks" mark (Safelight palette) with CoreGraphics on the macOS icon grid; `Contents.json` in the appiconset references the output filenames.
