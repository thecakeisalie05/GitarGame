# GitarGame alpha.14 — gameplay readability refinement

Date: 2026-09-27

## Goal

Make the strike zone easier to read without adding noisy arcade effects.

## Requested behavior

1. Inactive fret receptors should remain visible over the strike bar.
2. Hit feedback should be more noticeable and shaped like the note itself rather than a generic ping.
3. Misses should get a distinct but restrained animation, primarily by visibly turning the missed gem red.

## Implementation

- Lowered the strike-bar geometry and raised receptor caps above it.
- Increased inactive receptor opacity and added a dark pedestal to preserve each fret silhouette against bright bars/grid lines.
- Replaced alpha.13 projected 2D ripple rings with a short-lived 3D ghost of the actual hit gem.
- Hit feedback preserves normal, HOPO, tap, chord, and open-note silhouettes.
- Hit ghosts brighten, expand slightly, lift away from the highway, and fade on a realtime clock independent of video calibration.
- Missed notes now preserve their authored note type while transitioning toward red.
- Miss animation adds a small throb followed by slight shrink and partial fade as the gem passes behind the hit line.
- Open-note misses use the same color/scale/fade treatment on the wide bar-shaped gem.
- Extended gameplay-feedback regression tests for hit-bloom and miss-animation curves.

## Architecture notes

Hit classification is cached in Session at judgment time (mask/open/HOPO/tap) so feedback can match the exact gem that was struck without keeping already-hit chart geometry alive at the receptor. Miss animation continues to use each note's own judgedAt timestamp, keeping it attached to the actual missed gem.

## Verification plan

Release is gated on Windows source generation, full native build/link, chart compatibility tests, MIDI sustain tests, calibration estimator tests, gameplay-feedback tests, packaging, and alpha.14 publication.
