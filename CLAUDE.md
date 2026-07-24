# CLAUDE.md — Barik Enhanced

## Project memory in the LLM wiki

**Wiki path:**
```
~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Obsidian/llm-wiki/docs/wiki/barik/
```

**Read order:** `README.md` → `gotchas.md` → `release.md`.

## Update the wiki when you learn something worth remembering
Non-obvious constraints, workarounds, decisions, footguns → write back and bump `updated:`.

## Critical rules
1. **Version 1.2.9 = rollback to 1.2.6 functionality** — don't trust version numbers blindly; read CHANGELOG.
2. **macOS 14.0+ only.** SwiftUI APIs require Sonoma or later.
3. **Notarization required** for distribution outside the App Store.
4. **Don't regress performance** — the fork's identity is "performance optimizations" over upstream Barik.

## Quick orientation
Swift + SwiftUI macOS menu bar app. Fork of `mocki-toki/barik`. Distributed via GitHub Releases (zip download) — no Homebrew tap.

## Style
Wiki conventions: `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Obsidian/llm-wiki/CLAUDE.md`.
