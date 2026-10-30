# Capture and measurement kit

The audit's screenshots, accessibility dumps and contrast numbers were made with the tools on this page. Spec acceptance checks that say "capture", "ax dump" or "contrast" mean these exact tools. They change no app code and write nothing to the real library.

You need: a built Debug app (`xcodegen generate`, then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build`), `/usr/bin/python3` with Pillow (`python3 -c "import PIL"`), and Accessibility and Screen Recording permission for the terminal that runs them (System Settings > Privacy & Security). The tools take focus and, for dark captures, flip the system appearance for a few seconds.

## 1. Install the tools

Run once. Everything lives in `/tmp/mc-audit-tools` and screenshots go to `/tmp/mc-audit-shots` unless `CAP_OUT` says otherwise.

```bash
mkdir -p /tmp/mc-audit-tools /tmp/mc-audit-shots && cd /tmp/mc-audit-tools

cat > winid.swift <<'EOF'
import CoreGraphics
import Foundation
// winid <pid>: one line per window of that pid: id x y w h layer onscreen name
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!,
          w[kCGWindowLayer as String] as? Int ?? -1, w[kCGWindowIsOnscreen as String] as? Bool ?? false,
          w[kCGWindowName as String] as? String ?? "")
}
EOF
swiftc -O winid.swift -o winid

cat > ax.swift <<'EOF'
import AppKit
import ApplicationServices
// ax dump <pid> [maxDepth] | press <pid> <match> [index] | pressrole <pid> <role> <match> [index]
// ax setvalue <pid> <role> <match> <value> | focus <pid> <role> <match> | focused <pid>
// ax action <pid> <role> <match> <AXAction> | resize <pid> <x> <y> <w> <h>
// <match> is a case-insensitive substring of title, description, identifier or value; prefix "=" for an exact match.
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { guard let v = attr(e, n) else { return "" }; if let s = v as? String { return s }; if let x = v as? NSNumber { return x.stringValue }; return "" }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    guard let v = attr(e, kAXChildrenAttribute), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
    return (v as! [AnyObject]).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
}
func actions(_ e: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyActionNames(e, &n); return (n as? [String]) ?? [] }
func walk(_ e: AXUIElement, _ d: Int = 0, _ maxD: Int = 60, _ f: (AXUIElement, Int) -> Void) { f(e, d); if d < maxD { for c in children(e) { walk(c, d + 1, maxD, f) } } }
func matches(_ e: AXUIElement, _ needle: String) -> Bool {
    let n = needle.lowercased()
    for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute] {
        let s = str(e, a).lowercased()
        if n.hasPrefix("=") ? s == String(n.dropFirst()) : s.contains(n) { return true }
    }
    return false
}
func i(_ x: CGFloat) -> String { x.isFinite && abs(x) < 1e9 ? String(Int(x)) : "?" }
let a = CommandLine.arguments, cmd = a[1], app = AXUIElementCreateApplication(pid_t(a[2])!)
AXUIElementSetMessagingTimeout(app, 5)
func find(_ role: String?, _ n: String) -> [AXUIElement] { var o: [AXUIElement] = []; walk(app) { e, _ in if (role == nil || str(e, kAXRoleAttribute) == role!) && matches(e, n) { o.append(e) } }; return o }
switch cmd {
case "dump":
    walk(app, 0, a.count > 3 ? Int(a[3])! : 60) { e, d in
        let f = frame(e); var l = String(repeating: "  ", count: d) + str(e, kAXRoleAttribute)
        let sub = str(e, kAXSubroleAttribute); if !sub.isEmpty { l += "/\(sub)" }
        for (k, n) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("value", kAXValueAttribute), ("help", kAXHelpAttribute)] {
            let v = str(e, n); if !v.isEmpty { l += " \(k)=\(String(v.prefix(80)).debugDescription)" }
        }
        if str(e, kAXEnabledAttribute) == "0" { l += " [disabled]" }
        if str(e, kAXFocusedAttribute) == "1" { l += " [focused]" }
        l += " @\(i(f.minX)),\(i(f.minY)) \(i(f.width))x\(i(f.height))"
        let acts = actions(e).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
        if !acts.isEmpty { l += " acts=\(acts.joined(separator: ","))" }
        print(l)
    }
case "press", "pressrole":
    let role: String? = cmd == "pressrole" ? a[3] : nil, n = cmd == "pressrole" ? a[4] : a[3]
    let ix = cmd == "pressrole" ? 5 : 4, idx = a.count > ix ? Int(a[ix])! : 0, found = find(role, n)
    guard idx < found.count else { print("NOTFOUND \(n) (\(found.count))"); exit(2) }
    print("press -> \(AXUIElementPerformAction(found[idx], kAXPressAction as CFString).rawValue)")
case "action":
    guard let e = find(a[3], a[4]).first else { print("NOTFOUND"); exit(2) }
    print("action -> \(AXUIElementPerformAction(e, a[5] as CFString).rawValue)")
case "setvalue":
    guard let e = find(a[3], a[4]).first else { print("NOTFOUND"); exit(2) }
    print("set -> \(AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, a[5] as CFString).rawValue)")
case "focus":
    guard let e = find(a[3], a[4]).first else { print("NOTFOUND"); exit(2) }
    print("focus -> \(AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)")
case "focused":
    guard let v = attr(app, kAXFocusedUIElementAttribute) else { print("none"); break }
    let e = v as! AXUIElement, f = frame(e)
    print(str(e, kAXRoleAttribute), "desc=\(str(e, kAXDescriptionAttribute))", "value=\(String(str(e, kAXValueAttribute).prefix(40)).debugDescription)", "@\(i(f.minX)),\(i(f.minY)) \(i(f.width))x\(i(f.height))")
case "resize":
    let ws = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    guard let w = ws.first(where: { str($0, kAXSubroleAttribute) == "AXStandardWindow" }) else { print("nowin"); exit(2) }
    var p = CGPoint(x: Double(a[3])!, y: Double(a[4])!), s = CGSize(width: Double(a[5])!, height: Double(a[6])!)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    print("resized", frame(w))
default: print("unknown")
}
EOF
swiftc -O ax.swift -o ax

cat > cap.py <<'EOF'
#!/usr/bin/env python3
"""cap.py shot PID NAME | small PID | big PID. Sheets are inside the main window capture; popovers and menus are
composited from their own windows. CAP_ORIGIN="x,y" moves the window (default 40,60 on the main display)."""
import os, subprocess, sys, time
from PIL import Image
T, OUT = "/tmp/mc-audit-tools", os.environ.get("CAP_OUT", "/tmp/mc-audit-shots")
OX, OY = map(int, os.environ.get("CAP_ORIGIN", "40,60").split(","))
def windows(pid):
    rows = subprocess.run([f"{T}/winid", str(pid)], capture_output=True, text=True).stdout.splitlines()
    out = []
    for r in rows:
        wid, x, y, w, h, layer, on = r.split(" ", 7)[:7]
        if on == "true" and float(w) >= 30 and float(h) >= 30:
            out.append((int(wid), float(x), float(y), float(w), float(h)))
    return out
def shot(pid, name):
    if os.environ.get("CAP_NOFRONT") != "1":
        subprocess.run([f"{T}/front.sh", str(pid)], capture_output=True); time.sleep(0.6)
    ws = windows(pid)
    main = max(ws, key=lambda t: t[3] * t[4])
    caps = []
    for (wid, x, y, w, h) in ws:
        p = f"/tmp/mc-cap-{wid}.png"
        subprocess.run(["screencapture", "-x", "-o", "-l", str(wid), p], check=True)
        caps.append((Image.open(p).convert("RGBA"), wid, x, y, w, h)); os.remove(p)
    mim = [c for c in caps if c[1] == main[0]][0][0]
    scale = mim.size[0] / main[3]
    extra = [c for c in caps if c[1] != main[0] and c[0].size != mim.size]
    boxes = [(main[1], main[2], main[3], main[4])] + [(c[2], c[3], c[4], c[5]) for c in extra]
    x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    x1, y1 = max(b[0] + b[2] for b in boxes), max(b[1] + b[3] for b in boxes)
    canvas = Image.new("RGBA", (round((x1 - x0) * scale), round((y1 - y0) * scale)))
    canvas.alpha_composite(mim, (round((main[1] - x0) * scale), round((main[2] - y0) * scale)))
    for (im, _, x, y, w, h) in reversed(extra):
        im = im.resize((round(w * scale), round(h * scale)))
        canvas.alpha_composite(im, (round((x - x0) * scale), round((y - y0) * scale)))
    path = f"{OUT}/{name}.png"; canvas.save(path); print(path, canvas.size)
def resize(pid, w, h):
    print(subprocess.run([f"{T}/ax", "resize", str(pid), str(OX), str(OY), str(w), str(h)], capture_output=True, text=True).stdout.strip())
if sys.argv[1] == "shot": shot(sys.argv[2], sys.argv[3])
elif sys.argv[1] == "small": resize(sys.argv[2], 1100, 692)   # the minimum window: 1100x640 content + 52 pt toolbar
elif sys.argv[1] == "big": resize(sys.argv[2], 1680, 1050)
EOF
chmod +x cap.py

cat > contrast.py <<'EOF'
#!/usr/bin/env python3
"""contrast.py IMAGE x0 y0 x1 y1: WCAG contrast of the box. Background = most common colour, foreground = the pixel
with the highest contrast to it. At 1x, anti-aliasing can only lower the result, so the true ratio is at least this."""
import sys
from collections import Counter
from PIL import Image
def lum(c):
    f = lambda v: (v / 255) / 12.92 if v / 255 <= 0.03928 else (((v / 255) + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])
def ratio(a, b):
    la, lb = lum(a), lum(b); return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
px = list(Image.open(sys.argv[1]).convert("RGB").crop(tuple(map(int, sys.argv[2:6]))).getdata())
bg = Counter(px).most_common(1)[0][0]; fg = max(px, key=lambda p: ratio(p, bg))
print(f"{ratio(bg, fg):.2f}:1 bg={bg} fg={fg}")
EOF
chmod +x contrast.py

cat > launch.sh <<'EOF'
#!/bin/bash
# launch.sh HOME -> prints the app pid. HOME is a throwaway directory; the real library is never touched.
H=$1; APP="${MLXC_APP:?export MLXC_APP=<repo>/build/Build/Products/Debug/mlx-create.app first}"
mkdir -p "$H"
open -n --env CFFIXED_USER_HOME="$H" "$APP" --args -MLXCSmokeHome "$H" -ApplePersistenceIgnoreState YES
for _ in $(seq 1 30); do P=$(pgrep -f "Contents/MacOS/mlx-create -MLXCSmokeHome $H" | head -1); [ -n "$P" ] && break; sleep 0.5; done
echo "$P"
EOF
cat > quit.sh <<'EOF'
#!/bin/bash
# quit.sh HOME: stops the app and any engine whose command line holds HOME. Never matches by process name.
H=$1
for P in $(pgrep -f "MLXCSmokeHome $H"); do kill -TERM "$P"; done; sleep 4
for P in $(pgrep -f "$H/"); do kill -TERM "$P"; done; sleep 1
pgrep -fl "$H" || echo clean
EOF
cat > front.sh <<'EOF'
#!/bin/bash
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true"
EOF
cat > dark.sh <<'EOF'
#!/bin/bash
# dark.sh on|off: flips the SYSTEM appearance. Always run "dark.sh off" afterwards.
[ "$1" = on ] && V=true || V=false
osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $V"
EOF
chmod +x *.sh
```

Before using `launch.sh`, run `export MLXC_APP="$(git rev-parse --show-toplevel)/build/Build/Products/Debug/mlx-create.app"` from the repository (or from a worktree whose app you built).

## 2. Protect the real preferences

`CFFIXED_USER_HOME` isolates the library, models and engine, but not `UserDefaults.standard` (`docs/solutions/developer-experience/launch-app-with-empty-library-for-first-run-testing.md`). Before the first launch:

```bash
defaults export com.fearless.mlx-create /tmp/mc-audit-defaults-backup.plist
defaults write com.fearless.mlx-create civitaiIncludeNSFW -bool false   # keep NSFW previews out of screenshots
```

After the last quit: `defaults import com.fearless.mlx-create /tmp/mc-audit-defaults-backup.plist`.

## 3. Homes used by the audit

- **Empty library:** `launch.sh /tmp/mc-audit-empty` on a fresh directory. Shows the first-launch canvas.
- **One model installed:** symlink the model into the throwaway home; never copy it.

  ```bash
  H=/tmp/mc-audit-full; W="$H/Library/Application Support/mlx-create/Models/Weights"
  R="$HOME/Library/Application Support/mlx-create/Models/Weights"
  mkdir -p "$W/Runpod" && ln -s "$R/Runpod/FLUX.2-klein-4B-mflux-4bit" "$W/Runpod/FLUX.2-klein-4B-mflux-4bit"
  ```

- **Enhancer installed as well:** symlink `McG-221/gemma-4-E4B-it-heretic-mlx-4Bit` the same way, launch once, quit, then copy its `installed_model` row from a copy of the real database (a symlinked folder alone reads as "unverified" and Enhance opens the install sheet):

  ```bash
  cp "$HOME/Library/Application Support/mlx-create/Library/library.sqlite" /tmp/real-copy.sqlite
  sqlite3 "$H/Library/Application Support/mlx-create/Library/library.sqlite" \
    "attach '/tmp/real-copy.sqlite' as r; insert or replace into installed_model select * from r.installed_model where repo = 'McG-221/gemma-4-E4B-it-heretic-mlx-4Bit';"
  rm -f /tmp/real-copy.sqlite*
  ```

## 4. Drive, capture, measure

```bash
cd /tmp/mc-audit-tools; P=$(./launch.sh /tmp/mc-audit-full); sleep 10
./cap.py small $P && ./cap.py shot $P example_small_light        # 1100x692 window = 1100x640 content
./cap.py big $P && ./cap.py shot $P example_large_light          # 1680x1050 window
./dark.sh on; sleep 1.5; ./cap.py shot $P example_large_dark; ./dark.sh off
./ax dump $P > /tmp/ax.txt                                       # roles, labels, frames (screen points), enabled state
./ax setvalue $P AXTextArea "Prompt" "a lighthouse at dusk"      # types into the prompt through accessibility
./ax press $P "=Generate"                                        # presses the first element whose label is exactly "Generate"
./contrast.py /tmp/mc-audit-shots/example_small_light.png 430 296 730 318
./quit.sh /tmp/mc-audit-full
```

Frames in `ax dump` are global screen points. A control is "visible without scrolling" when its frame lies inside the window frame and its nearest `AXScrollArea` ancestor shows no `AXScrollBar` with a value above `0`; the simplest check is that the control's frame is fully inside the window frame right after launch, with no scrolling done.

Notes from the audit runs:

- `screencapture -l` fails while the screen is locked. Captures taken then are blank; re-run them.
- The engine log is at `<home>/Library/Application Support/mlx-create/Engine/.mlx-serve/logs/`. Check it before blaming the app for a memory refusal: another task on the same Mac can hold the memory.
- A `kill -9` of the engine child, repeated four times within five minutes, exhausts the restart budget and shows the failed-engine banner (`EngineSupervisor`, `RestartBudget`).
