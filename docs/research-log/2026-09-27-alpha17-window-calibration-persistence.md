# GitarGame alpha.17 — hit-window feel + persistent calibration

Date: 2026-09-27

## User feedback

After alpha.16, latency/response felt correct but the effective gameplay window still felt materially stricter than Clone Hero. Calibration values also did not reliably survive session/release changes.

## Findings

- Alpha.16 correctly removed render-frame timing jitter by judging XInput at the original poll timestamp.
- A community-reported ~140 ms Clone Hero total window does not fully describe normal-engine feel: Clone Hero's non-Precision behavior is more forgiving around HOPO/tap frontend handling.
- The existing audio/video offsets were serialized in config.ini, but config.ini is portable-folder-local. That is not robust persistence for a game distributed as replacement EXEs/ZIPs.

## Changes

### Gameplay feel

- Kept the alpha.16 timestamped XInput pipeline unchanged.
- Relaxed the untouched alpha.16 default from +/-70 ms to +/-90 ms (~180 ms total).
- Custom user hit-window values are preserved during migration.
- Added early HOPO/tap frontend arming with cancellation when the required fret state or HOPO combo is lost.
- Added regression coverage for frontend hold validity.

### Calibration persistence

- Added a small versioned calibration-profile format and round-trip tests.
- On Windows the canonical persistent mirror is %LOCALAPPDATA%/GitarGame/calibration.ini.
- Startup loads config.ini first, then the persistent calibration profile.
- If the persistent file is absent, existing config.ini calibration values seed it automatically.
- Auto calibration, manual Settings offset changes, and F7/F8/F9 timing changes update both config.ini and the persistent profile.
- This preserves calibration across restarts, executable replacement and portable-folder changes.

## Verification plan

Alpha.17 remains gated on the full Windows application build plus chart compatibility, MIDI sustain, calibration estimator, gameplay feedback, guitar-engine, and calibration-profile tests, then packaging/release publication.

## Human acceptance

The key playtest is a familiar Clone Hero chart with ordinary strums plus early-fretted HOPO ladders. If +/-90 ms is still perceptibly too strict or too loose, the timing value remains configurable without changing the low-latency input architecture.
