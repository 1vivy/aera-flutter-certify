# Flutter Certify for AERA Recovery

Measures how well a Flutter app runs inside AERA Recovery and writes a graded
report. Built from aera-flutter-template, so it runs on exactly the runtime
apps get.

## What it checks

It runs by itself on launch, in this order:

1. **Interactive** (30 s each, or Skip): tap the circle 3 times (touch to
   frame latency), type `aera` + Enter (AERA keyboard to Flutter text field),
   press AERA's Back button (route pop).
2. **Probes**: Dart to Rust call cost, Rust panic handling, Rust threads,
   Dart isolates, write/read speed of `/profile`, `/downloads` and `/tmp`,
   DNS, TCP, HTTPS, glyph coverage per script, time zone, clipboard,
   renderer, speaker tone.
3. **Frames**: seven GPU scenes (idle, list scroll, canvas particles, blur,
   text layout, image upload, page transitions), 5 s each, graded on the 90th
   percentile frame time (A ≤ 16.7 ms, B ≤ 33 ms, C ≤ 50 ms).
4. **Memory**: resident size at start, growth over 3 repeats of the
   allocation-heavy scenes, peak.
5. **Lifecycle**: whether `/profile` survived since the last launch and
   whether the last launch finished, crashed or was killed.

The report shows on screen and is saved to `/sdcard/AERA/Downloads/aera-cert-latest.json`
(plus a timestamped copy). The bug button opens the **crash lab**: Dart
exception, UI freeze, Rust abort, segfault, memory climb and normal exit. Each
one records what it did, and the next launch reports whether AERA let the app
come back.

Everything browser-slot specific is in `lib/cert/host.dart`, so the same
suite runs unchanged on AERA's generic pixel + GPU host.

## Run it

```sh
tool/certify_sim.sh        # PC simulator, interactive checks scripted
tool/aera.sh package       # build/aera/Flutter-Certify-<version>.aerap
```

Environment switches (simulator): `AERA_CERT_QUICK=1` shorter scenes,
`AERA_CERT_EXIT=1` close when done, `AERA_CERT_LEAK_ONLY=1` only the leak
check, `AERA_CERT_LEAK_SCENES=upload,routes`, `AERA_CERT_LEAK_ROUNDS=3`.

`tool/aera.sh package` makes a release (AOT) build on the release engine, like
every app built from the template; `AERA_RENDERER=vulkan` or `impeller` builds
the other renderers. The simulator always runs a debug (JIT) build, which makes
startup and frame times pessimistic; the report says which mode and renderer
it ran with, and each frame scene also records the embedder's own costs
(waiting for AERA, readback) and the GPU clock when the phone exposes them.

After reinstalling, clear the old app from Recents (or reboot recovery): AERA
keeps it running otherwise. The report header shows the build it came from.
