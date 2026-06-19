# Changelog

## Unreleased - 2026-06-19

Fix the Ashita v4 build so it actually targets Ashita v4.

The build defaulted to the `ASHITA_V3` target and the release workflow never
passed `-DTARGET_PLATFORM=ASHITA_V4`, so it compiled the v3 sources against the
v4 SDK headers and could not produce a usable Ashita v4 `Nameplate.dll`.

- `CMakeLists.txt`: default `TARGET_PLATFORM` is now `ASHITA_V4` (matching the
  documented "(default)" comment) and the default `ASHITA_SDK_PATH` points at an
  Ashita v4 SDK (`../Ashita-v4beta/plugins/sdk`).
- `.github/workflows/nameplate.yml`: the configure step now explicitly passes
  `-DTARGET_PLATFORM=ASHITA_V4`. The SDK is checked out from `Ashita-v4beta@main`,
  so the plugin is always built against the current `ASHITA_INTERFACE_VERSION`
  (4.30 at the time of writing) and is not flagged "out of date".

No gameplay/runtime logic was changed; the v4 source is already compatible with
the current SDK. See `V4-FIX-NOTES.md` for the full diagnosis.

## 0.60 - 2026-01-01

Add Ashita v3 version

Add support for the next version of the Ashita v4 beta

Add fractional font scaling support

## 0.51 - 2024-06-09

Add support for client version 30240604_1 ("June 10, 2024 (JST) Version Update")

## 2024-03-04

No actual code changes

Source code license changed to GNU GPL, version 3

## 0.50 - 2023-12-03

`DamageFontSizeInPx` and `/nameplate damagefontsize` added

## 0.40 - 2023-01-21

`NameMode` added

Commands for updating settings added

## 0.03 - 2023-01-07

Fixed defect preventing loading from startup scripts

## 0.02 - 2023-01-03

`HideStars` added

## 0.01 - 2022-09-30

Initial release
