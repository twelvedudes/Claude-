# Nameplate — Ashita v4 build fix notes

This is a fork of [Shirk/Nameplate](https://github.com/Shirk/Nameplate) (an
abandoned project) with the **Ashita v4 build repaired**. The goal was to get a
`Nameplate.dll` that loads in current Ashita v4 again.

## TL;DR

The plugin's Ashita v4 *source code was already fine* and is compatible with the
current Ashita v4 SDK (interface version **4.30**). The only thing broken was the
**build configuration** — it never actually built the v4 target, so no usable v4
DLL was ever produced. Two small config changes fix that.

## What was wrong

Nameplate builds one of three targets selected by the CMake cache variable
`TARGET_PLATFORM` (`ASHITA_V3`, `ASHITA_V4`, or `WINDOWER_V4`).

1. **`CMakeLists.txt` defaulted to the wrong target.** The default was
   `ASHITA_V3`, even though the comment directly above it documents `ASHITA_V4`
   as "(default)". The default `ASHITA_SDK_PATH` also pointed at a v3 path
   (`../Ashita-v3/plugins`).

2. **The release workflow never selected the v4 target.**
   `.github/workflows/nameplate.yml` checks out the Ashita **v4** SDK and points
   `ASHITA_SDK_PATH` at it, but it **did not pass `-DTARGET_PLATFORM=ASHITA_V4`**.
   So CMake used the default (`ASHITA_V3`) and tried to compile the **v3**
   sources against the **v4** headers.

   That cannot work: the v3 translation unit
   (`src/Ashita-v3/Ashita.cpp`) does `#include "ADK/Ashita.h"` (a path that does
   not exist in the v4 SDK) and uses the v3 API (`plugininfo_t`,
   `GetPluginInfo()`, the v3 `HandleCommand(const char*, int32_t)` signature,
   `GetAshitaInstallPathA()`, and the `CreatePlugin`/`CreatePluginInfo` exports).
   None of those exist in the Ashita v4 SDK, so the build fails / never yields a
   loadable v4 plugin.

This lines up with the repo state: the last commit was *"was to be the 0.60
update"* and the project is marked **Abandoned** — the v4 release was left
unfinished.

## What was changed

Only build configuration — **no runtime/gameplay logic was touched.**

### `CMakeLists.txt`
- Default `TARGET_PLATFORM` → `ASHITA_V4` (matches the documented intent).
- Default `ASHITA_SDK_PATH` → `../Ashita-v4beta/plugins/sdk` (a plain checkout of
  `AshitaXI/Ashita-v4beta` works as the SDK).

### `.github/workflows/nameplate.yml`
- The configure step now passes `-DTARGET_PLATFORM=ASHITA_V4` explicitly, so the
  build is correct regardless of any cached default.
- The SDK checkout folder was renamed `ashita-sdk-416` → `ashita-v4-sdk` (it
  pulls `ref: main`, i.e. whatever the current interface version is — 4.30 today,
  not 4.16), and the configure step references the new path.

### Why this is sufficient for "out of date" errors
Ashita refuses to load a plugin whose `expGetInterfaceVersion()` does not match
the running client's `ASHITA_INTERFACE_VERSION`. Nameplate returns
`ASHITA_INTERFACE_VERSION` straight from whatever SDK header it is compiled
against (`src/Ashita/Ashita.cpp`). Because the workflow checks out the SDK at
`main`, every build automatically reports the current interface version. Rebuild
against the current SDK whenever Ashita bumps the version.

## How to get a working `Nameplate.dll`

> A Windows toolchain is required (clang + lld, 32-bit, C++23/26 with modules).
> This cannot be built or tested from a Linux/macOS box, and definitely not from
> this Claude session — see "Limitations" below.

### Option A — GitHub Actions (easiest)
1. Put this project at the **root** of a GitHub repo (e.g. fork
   `Shirk/Nameplate` and apply these changes, or push the contents of this
   `Nameplate/` folder as their own repo). The workflow must live at
   `.github/workflows/nameplate.yml` in the repo root to run.
2. Actions → **"Build and Release Nameplate.dll"** → **Run workflow**, and enter
   a version tag (e.g. `0.60-v4`).
3. Download `Nameplate.dll` from the run's artifact (or the auto-created release).

### Option B — Local build (Windows)
```powershell
# From the project root, with clang/ninja on PATH and an Ashita v4 SDK nearby:
git clone https://github.com/AshitaXI/Ashita-v4beta ../Ashita-v4beta

cmake -B build -G Ninja `
  -DCMAKE_C_COMPILER=clang -DCMAKE_C_COMPILER_FORCED=ON `
  -DCMAKE_CXX_COMPILER=clang -DCMAKE_CXX_COMPILER_FORCED=ON `
  -DCMAKE_BUILD_TYPE=Release `
  -DTARGET_PLATFORM=ASHITA_V4 `
  -DASHITA_SDK_PATH=../Ashita-v4beta/plugins/sdk

cmake --build build
# -> build/Nameplate.dll
```

## Install & use (Ashita v4)
1. Copy `Nameplate.dll` to `<Ashita v4 folder>\plugins\Nameplate.dll`.
2. In game: `/load Nameplate`, then `/nameplate help`.
3. Settings live in `config\nameplate\defaults.ini`; `/nameplate save` /
   `/nameplate load` to persist. See the main `README.md` for the full command
   list.

## Limitations / what is NOT verified

- **No binary was produced or tested here.** This environment is Linux and cannot
  cross-compile a Windows 32-bit DLL with the required clang/modules toolchain,
  nor run FFXI/Ashita. The fix is verified by source inspection against the
  current SDK, not by a runtime load test. Please build (Option A/B) and confirm
  in game.
- **Memory signatures were not re-validated against the current client.**
  Nameplate works by scanning `FFXiMain.dll` for byte-pattern signatures (in
  `src/Nameplate.cpp`) and patching the name/damage rendering. If Square Enix
  has changed those code paths in a client update *since these signatures were
  written*, `Init()` will fail with a negative error code and the plugin will
  report a load error even though it is no longer "out of date". That is a
  separate problem from this build fix and would require updating the signatures
  against the current `FFXiMain.dll`. If you hit a load error after building,
  note the error code it prints — that points at which signature failed.
