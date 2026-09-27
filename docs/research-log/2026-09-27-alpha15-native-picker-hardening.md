# GitarGame alpha.15 — Windows native-picker hardening

Date: 2026-09-27

## Trigger

The alpha.14 Windows executable was reported by Edge as "Virus detected" while alpha.13 had downloaded successfully. The alpha.13 → alpha.14 runtime diff contained only gameplay/rendering changes, so the visual code itself did not introduce malware-like behavior. However, the executable still inherited an older runtime folder-picker bridge that spawned a hidden PowerShell/WinForms process.

## Goal

Remove avoidable heuristic triggers from the runtime executable without asking users to disable or whitelist antivirus protection, while preserving the alpha.14 gameplay changes.

## Changes

- Replaced the runtime `powershell.exe -STA` + WinForms `FolderBrowserDialog` bridge with the Windows Common Item Dialog.
- Added `src/native_folder_picker.cpp` using `IFileOpenDialog` with `FOS_PICKFOLDERS`, `FOS_FORCEFILESYSTEM`, `FOS_PATHMUSTEXIST`, and `FOS_NOCHANGEDIR`.
- The picker is owned by GitarGame's native HWND.
- Fullscreen is temporarily exited before showing the owned dialog, then restored afterward.
- UTF-16 Windows paths are explicitly converted to UTF-8 before returning to the existing filesystem layer.
- Shell/COM headers are isolated in a separate static helper library; the raylib translation unit sees only a void-pointer/string interface.
- Added a source-generation hardening gate that aborts alpha.15 if the generated executable source still contains the old runtime PowerShell, `_popen`, or WinForms picker implementation.

## Scope / interpretation

This change is a hardening measure and a new binary build, not proof that the earlier antivirus detection was caused by the picker. The exact Defender detection name was not available at implementation time. If alpha.15 is still detected, the next diagnostic artifact should be the exact Windows Security Protection History detection name and the alpha.15 executable hash.

## Verification

Alpha.15 is gated on Windows source generation, compilation of the isolated shell helper, full application link, all existing chart/MIDI/calibration/gameplay regression tests, packaging, and release publication.
