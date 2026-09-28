import 'dart:io';
import 'dart:ui';

import 'package:flutter/scheduler.dart';

/// Seconds since this process started, from `/proc/self/stat`. Null where
/// `/proc` is unreadable.
double? processAgeSeconds() {
  try {
    final stat = File('/proc/self/stat').readAsStringSync();
    final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    // Field 22 of stat (start time in clock ticks); fields[0] is field 3.
    final startTicks = int.parse(fields[19]);
    final uptime = double.parse(File('/proc/uptime').readAsStringSync().split(' ').first);
    const ticksPerSecond = 100; // USER_HZ on Linux and Android arm64
    return uptime - startTicks / ticksPerSecond;
  } catch (_) {
    return null;
  }
}

int rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);
int peakRssMb() => ProcessInfo.maxRss ~/ (1024 * 1024);

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final index = ((sorted.length - 1) * p).round();
  return sorted[index];
}

/// Frame statistics over one measurement window.
class FrameStats {
  FrameStats(List<FrameTiming> timings, this.wallSeconds)
    : frames = timings.length,
      build = timings.map((t) => t.buildDuration.inMicroseconds / 1000).toList()..sort(),
      raster = timings.map((t) => t.rasterDuration.inMicroseconds / 1000).toList()..sort(),
      total = timings.map((t) => t.totalSpan.inMicroseconds / 1000).toList()..sort();

  final int frames;
  final double wallSeconds;
  final List<double> build;
  final List<double> raster;
  final List<double> total;

  double get fps => wallSeconds > 0 ? frames / wallSeconds : 0;
  double get buildP90 => _percentile(build, 0.9);
  double get rasterP50 => _percentile(raster, 0.5);
  double get rasterP90 => _percentile(raster, 0.9);
  double get rasterP99 => _percentile(raster, 0.99);
  double get totalP90 => _percentile(total, 0.9);

  /// Frames whose build or raster took longer than one 60 Hz vsync.
  int get janky => [
    for (var i = 0; i < build.length; i++) i,
  ].where((i) => build[i] > 16.7 || raster[i] > 16.7).length;

  Map<String, Object?> toJson() => {
    'frames': frames,
    'seconds': double.parse(wallSeconds.toStringAsFixed(2)),
    'fps': double.parse(fps.toStringAsFixed(1)),
    'buildP90Ms': double.parse(buildP90.toStringAsFixed(2)),
    'rasterP50Ms': double.parse(rasterP50.toStringAsFixed(2)),
    'rasterP90Ms': double.parse(rasterP90.toStringAsFixed(2)),
    'rasterP99Ms': double.parse(rasterP99.toStringAsFixed(2)),
    'totalP90Ms': double.parse(totalP90.toStringAsFixed(2)),
  };
}

/// Collects [FrameTiming]s between [start] and [stop].
class FrameRecorder {
  final List<FrameTiming> _timings = [];
  final Stopwatch _clock = Stopwatch();

  void _onTimings(List<FrameTiming> timings) => _timings.addAll(timings);

  void start() {
    _timings.clear();
    _clock
      ..reset()
      ..start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  Future<FrameStats> stop() async {
    // Timings are reported in batches; give the last batch a moment.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _clock.stop();
    return FrameStats(List.of(_timings), _clock.elapsedMicroseconds / 1e6);
  }

  /// Raster-finish times (microseconds, monotonic clock) seen so far.
  List<int> get rasterFinishes => [for (final t in _timings) t.timestampInMicroseconds(FramePhase.rasterFinish)];
}

/// The embedder's own per-frame costs, rewritten every 120 frames in
/// `/tmp/aera-flutter-stats` (sent fps, wait for AERA, readback, swizzle,
/// share of the frame copied). Null before the embedder has written it.
const embedderStatsFile = '/tmp/aera-flutter-stats';

void clearEmbedderStats() {
  try {
    File(embedderStatsFile).deleteSync();
  } catch (_) {}
}

Map<String, Object?>? readEmbedderStats() {
  try {
    final line = File(embedderStatsFile).readAsStringSync().trim();
    double? number(String pattern) =>
        double.tryParse(RegExp(pattern).firstMatch(line)?.group(1) ?? '');
    return {
      'line': line,
      'sentFps': number(r'frames sent ([\d.]+)/s'),
      'waitForAeraMs': number(r'waiting for AERA ([\d.]+) ms'),
      'readbackMs': number(r'readback ([\d.]+) ms'),
      'swizzleMs': number(r'swizzle ([\d.]+) ms'),
      'copiedPercent': number(r'copied ([\d.]+)%'),
    };
  } catch (_) {
    return null;
  }
}

/// GPU clock and load from KGSL, where the phone lets the app read them.
Map<String, Object?>? readGpu() {
  String? read(String path) {
    try {
      return File(path).readAsStringSync().trim();
    } catch (_) {
      return null;
    }
  }

  final hz = int.tryParse(read('/sys/class/kgsl/kgsl-3d0/gpuclk') ?? '');
  final busy = read('/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage');
  if (hz == null && busy == null) return null;
  return {'gpuMHz': hz == null ? null : hz ~/ 1000000, 'gpuBusy': busy};
}
