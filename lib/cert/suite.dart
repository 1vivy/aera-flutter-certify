import 'dart:async';
import 'dart:io';
import 'dart:ui' show FrameTiming, FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../src/rust/api/aera.dart' as aera;
import 'host.dart';
import 'metrics.dart';
import 'probes.dart';
import 'report.dart';
import 'scenes.dart';
import 'state.dart';

/// Timing captured in `main` before the first frame.
class Startup {
  static double? atMain;
  static double? atFirstFrame;
}

/// Runs the whole certification: interactive checks first (so the PC
/// simulator can script them at fixed times), then probes, GPU scenes and a
/// leak check, then shows and saves the report.
class Suite extends StatefulWidget {
  const Suite({super.key, required this.onDone});
  final void Function(Report report, String? path) onDone;

  @override
  State<Suite> createState() => _SuiteState();
}

class _SuiteState extends State<Suite> {
  final _env = Platform.environment;
  late final bool _quick = _env['AERA_CERT_QUICK'] == '1';
  late final Duration _sceneTime = Duration(milliseconds: _quick ? 2500 : 5000);
  late final Duration _waitTime = Duration(seconds: _quick ? 12 : 30);

  Widget _stage = const SizedBox();
  String _caption = 'Starting';
  Completer<void>? _skip;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _show(String caption, Widget stage) => setState(() {
    _caption = caption;
    _stage = stage;
  });

  /// Waits for [done] or the timeout or the Skip button, whichever is first.
  Future<bool> _await(Future<void> done) async {
    setState(() => _skip = Completer<void>());
    var ok = false;
    await Future.any([
      done.then((_) => ok = true),
      Future<void>.delayed(_waitTime),
      _skip!.future,
    ]);
    setState(() => _skip = null);
    return ok;
  }

  Future<void> _run() async {
    final host = HostProfile.detect();
    final state = RunState.load();
    final previous = state.status;
    state
      ..runs += 1
      ..status = 'running'
      ..save();

    final report = Report({
      'host': host.toJson(),
      'flutterMode': kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release'),
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'cpus': Platform.numberOfProcessors,
      'locale': aera.recoveryLocale(),
      'quick': _quick,
      'appVersion': const String.fromEnvironment('AERA_APP_VERSION'),
      'appBuild': const String.fromEnvironment('AERA_APP_BUILD'),
      'renderer': const String.fromEnvironment('AERA_RENDERER', defaultValue: 'gl'),
    });
    final mode = kDebugMode ? ' (debug JIT: frame and startup times are pessimistic)' : '';

    // Startup and persistence.
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    final first = Startup.atFirstFrame ??= processAgeSeconds();
    report.add(first == null
        ? Result('startup', 'first frame', Grade.info, '/proc not readable')
        : Result('startup', 'first frame', gradeBelow(first, 1.5, 3, 6),
            '${first.toStringAsFixed(2)} s from process start (Dart main at ${Startup.atMain?.toStringAsFixed(2)} s)$mode',
            {'mainSeconds': Startup.atMain, 'firstFrameSeconds': first}));
    report.add(Result('storage', 'profile persists', state.runs > 1 ? Grade.pass : Grade.info,
        state.runs > 1 ? 'run ${state.runs}: state from the last launch was kept' : 'first run: launch again to check persistence',
        {'runs': state.runs}));
    report.add(switch (previous) {
      'none' || 'finished' => Result('lifecycle', 'previous launch', Grade.info, 'previous launch: $previous'),
      'running' => Result('lifecycle', 'previous launch', Grade.info,
          'the previous run was stopped before it finished (closed, killed or crashed)'),
      _ => Result('lifecycle', 'relaunch after ${previous.replaceFirst('crash-test:', '')}', Grade.pass,
          'AERA let the app start again after a deliberate ${previous.replaceFirst('crash-test:', '')}'),
    });
    report.add(Result('memory', 'at start', Grade.info, '${rssMb()} MB resident', {'rssMb': rssMb()}));

    final leakOnly = _env['AERA_CERT_LEAK_ONLY'] == '1';
    if (!leakOnly) await _checks(report);
    await _leakCheck(report, (_env['AERA_CERT_LEAK_SCENES'] ?? 'upload,routes').split(','));
    await _finish(report, state);
  }

  Future<void> _checks(Report report) async {
    await _tapCheck(report);
    await _typeCheck(report);
    await _backCheck(report);

    _show('Probing environment, storage, network and fonts', const Center(child: CircularProgressIndicator()));
    for (final result in await runProbes(quick: _quick)) {
      report.add(result);
    }

    for (final scene in scenes) {
      report.add(await _measure(scene));
    }

  }

  Future<void> _leakCheck(Report report, List<String> ids) async {
    // Leak check: run the two allocation-heavy scenes again. Steady growth
    // round after round is a leak; a one-off jump is caches filling.
    final rounds = int.tryParse(_env['AERA_CERT_LEAK_ROUNDS'] ?? '') ?? 3;
    final before = rssMb();
    final perRound = <int>[];
    for (var round = 0; round < rounds; round++) {
      for (final id in ids) {
        final scene = scenes.firstWhere((s) => s.id == id);
        _show('Leak check ${round + 1}/$rounds: ${scene.title}', KeyedSubtree(key: UniqueKey(), child: scene.build()));
        await Future<void>.delayed(_sceneTime ~/ 2);
      }
      perRound.add(rssMb());
    }
    _show('Settling', const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = rssMb();
    final growth = before > 0 ? (after - before) / before : 0.0;
    report.add(Result('memory', 'growth over repeats', gradeBelow(growth * 100, 5, 15, 30),
        '$before MB → $after MB after $rounds more rounds (${perRound.join(', ')})',
        {'beforeMb': before, 'afterMb': after, 'perRoundMb': perRound}));
    final peak = peakRssMb();
    report.add(Result('memory', 'peak', gradeBelow(peak, 300, 600, 1000), '$peak MB peak resident (jail limit about 1.5 GB)',
        {'peakMb': peak}));

  }

  Future<void> _finish(Report report, RunState state) async {
    state
      ..status = 'finished'
      ..save();
    String? path;
    try {
      path = await report.save(aera.storageDirs().downloads);
    } catch (error) {
      report.add(Result('storage', 'save report', Grade.fail, '$error'));
    }
    for (final r in report.results) {
      debugPrint('aera-cert ${r.grade.label.padRight(4)} ${r.area}/${r.name}: ${r.summary}');
    }
    debugPrint('aera-cert report: $path');
    widget.onDone(report, path);
    if (_env['AERA_CERT_EXIT'] == '1') {
      await SystemNavigator.pop();
    }
  }

  Future<Result> _measure(Scene scene) async {
    final recorder = FrameRecorder();
    _show('${scene.title}: ${scene.what}', KeyedSubtree(key: ValueKey(scene.id), child: scene.build()));
    await Future<void>.delayed(const Duration(milliseconds: 400)); // warm-up
    clearEmbedderStats();
    recorder.start();
    await Future<void>.delayed(_sceneTime);
    final gpu = readGpu();
    final stats = await recorder.stop();
    final embedder = readEmbedderStats();
    final grade = stats.frames < 5 ? Grade.f : gradeBelow(stats.totalP90, 16.7, 33.4, 50);
    return Result('frames', scene.title, grade,
        '${stats.fps.toStringAsFixed(1)} fps, raster p90 ${stats.rasterP90.toStringAsFixed(1)} ms, '
        'build p90 ${stats.buildP90.toStringAsFixed(1)} ms, ${stats.janky}/${stats.frames} over 16.7 ms'
        '${embedder == null ? '' : '; embedder: ${embedder['line']}'}'
        '${gpu == null ? '' : '; GPU ${gpu['gpuMHz']} MHz ${gpu['gpuBusy'] ?? ''}'}',
        {...stats.toJson(), 'rssMb': rssMb(), 'embedder': ?embedder, 'gpu': ?gpu});
  }

  Future<void> _tapCheck(Report report) async {
    final latencies = <double>[];
    final done = Completer<void>();
    var taps = 0;

    void tapped(PointerDownEvent event) {
      final down = event.timeStamp.inMicroseconds;
      late void Function(List<FrameTiming>) watch;
      watch = (timings) {
        for (final t in timings) {
          final finish = t.timestampInMicroseconds(FramePhase.rasterFinish);
          if (finish > down) {
            latencies.add((finish - down) / 1000);
            SchedulerBinding.instance.removeTimingsCallback(watch);
            return;
          }
        }
      };
      SchedulerBinding.instance.addTimingsCallback(watch);
      taps++;
      _show('Tap the circle (${3 - taps} more)', _target(taps, tapped));
      if (taps >= 3 && !done.isCompleted) done.complete();
    }

    _show('Tap the circle 3 times', _target(0, tapped));
    final ok = await _await(done.future);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (latencies.isEmpty) {
      report.add(Result('input', 'touch to frame', ok ? Grade.fail : Grade.skipped, ok ? 'no frame followed the taps' : 'no taps'));
      return;
    }
    latencies.sort();
    final worst = latencies.last;
    report.add(Result('input', 'touch to frame', gradeBelow(worst, 50, 100, 200),
        '${latencies.length} taps: ${latencies.map((l) => l.toStringAsFixed(0)).join(', ')} ms from touch event to the answering frame',
        {'latenciesMs': latencies}));
  }

  Widget _target(int taps, void Function(PointerDownEvent) onDown) => Center(
    child: Listener(
      onPointerDown: onDown,
      child: Container(
        width: 160,
        height: 160,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.primaries[taps * 3 % Colors.primaries.length]),
        alignment: Alignment.center,
        child: Text('$taps', style: const TextStyle(fontSize: 48)),
      ),
    ),
  );

  Future<void> _typeCheck(Report report) async {
    final done = Completer<String>();
    final watch = Stopwatch()..start();
    _show(
      'Type "aera" and press Enter',
      Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Type aera'),
            onSubmitted: (text) {
              if (!done.isCompleted) done.complete(text);
            },
          ),
        ),
      ),
    );
    final ok = await _await(done.future);
    if (!ok) {
      report.add(Result('input', 'text entry', Grade.skipped, 'nothing was submitted'));
      return;
    }
    final text = await done.future;
    report.add(Result('input', 'text entry', text.trim().toLowerCase() == 'aera' ? Grade.pass : Grade.fail,
        'keyboard showed, "$text" submitted with Enter after ${watch.elapsedMilliseconds} ms'));
  }

  Future<void> _backCheck(Report report) async {
    final navigator = Navigator.of(context);
    final popped = navigator.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Back button check')),
        body: const Center(child: Text("Press AERA's Back button", style: TextStyle(fontSize: 22))),
      ),
    ));
    _show('Press Back', const SizedBox());
    final ok = await _await(popped);
    if (!ok && navigator.canPop()) navigator.pop();
    report.add(Result('input', 'Back button', ok ? Grade.pass : Grade.skipped,
        ok ? 'AERA Back popped the Flutter route' : 'no Back press'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(child: Text(_caption, style: Theme.of(context).textTheme.titleSmall)),
                  if (_skip != null) TextButton(onPressed: () {
                      if (!(_skip?.isCompleted ?? true)) _skip!.complete();
                    }, child: const Text('Skip')),
                ],
              ),
            ),
          ),
          Expanded(child: _stage),
        ],
      ),
    ),
  );
}
