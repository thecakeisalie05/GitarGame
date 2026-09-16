# Song package compatibility

GitarGame treats a song folder as a package rather than assuming a single chart/audio encoding.

## Discovery precedence

A folder is playable when it contains one of these chart files:

1. `notes.chart` (preferred when both are present)
2. `notes.mid`
3. `notes.midi`

The browser reads common metadata from `song.ini` and artwork from the usual album/cover filenames independently of chart encoding.

## Chart normalization

Both text `.chart` and Rock Band/Guitar Hero-style MIDI are normalized into the same internal `ChartData` model before gameplay. This keeps timing, rendering, hit logic, measure bars, Star Power and future ChartForge integration independent of the source format.

The initial MIDI compatibility target is five-fret `PART GUITAR`/`T1 GEMS`, with Expert notes, tempo/time-signature events, sustains, open notes, force-HOPO/force-strum/tap markers and Star Power phrases.

## Audio

Raylib 5.5 does not natively decode Ogg Opus (`.opus`). For song packages containing Opus stems, GitarGame decodes and mixes the stems through libopusfile into a temporary in-memory PCM WAV stream, then hands that stream to the existing raylib music transport. This preserves the same playback-clock path used by `.ogg`, `.mp3`, `.wav` and `.flac` songs instead of maintaining a second timing implementation.

Preview-only audio is excluded from the mix. Instrument/backing stems are combined into one playback stream for the current alpha.
