# Oye

A Mac menu bar app. Your people sit in the menu bar as faces: click one to text them.
Hold to talk, voice notes and file drops are next.

- `Sources/OyeCore` — people, messages, invites and timestamps. No AppKit, so it tests anywhere.
- `Sources/Oye` — the Mac app (SwiftUI + AppKit, macOS 14 or later).
- `supabase/migrations` — Oye's tables and functions. They live in the same Supabase project as
  Talkie and all start with `oye_`.
- `scripts/bundle.sh` — builds `build/Oye.app` and `build/Oye.zip` (ad hoc signed for now).

## Build

    swift build
    swift test
    scripts/bundle.sh release

Every push to `main` builds and tests on GitHub. The logs are copied to the `ci-logs-core` and
`ci-logs-mac` branches.

## Status

Not released. The migrations and the `oye-talk` function were applied to the Talkie project on
27 November 2026. Recording, sending and hold to talk have not been tried on a real Mac yet.
