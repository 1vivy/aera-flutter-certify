import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/api/cert.dart' as cert;
import 'state.dart';

/// Deliberate failures, run by hand on the phone. Each one records what it is
/// about to do, so the next launch's report says whether AERA recovered.
class CrashLab extends StatefulWidget {
  const CrashLab({super.key});
  @override
  State<CrashLab> createState() => _CrashLabState();
}

class _CrashLabState extends State<CrashLab> {
  String _note = 'Each test may end the app. Open it again from AERA afterwards; the next report shows whether it recovered.';
  int _heldMb = 0;

  void _arm(String kind) {
    final state = RunState.load()..status = 'crash-test:$kind';
    state.save();
  }

  Future<void> _memoryClimb() async {
    _arm('out-of-memory');
    while (mounted) {
      _heldMb = ((await cert.holdMemory(megabytes: 64)).toInt()) ~/ (1024 * 1024);
      setState(() => _note = 'Holding $_heldMb MB…');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tests = <(String, String, VoidCallback)>[
      ('Dart exception', 'Throws in a button handler. The app should keep running.', () {
        throw StateError('certification: deliberate Dart exception');
      }),
      ('Freeze UI 10 s', 'Blocks the UI thread. Does AERA stay responsive and the app come back?', () {
        _arm('ui-freeze');
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(end)) {}
        RunState.load()
          ..status = 'finished'
          ..save();
        setState(() => _note = 'UI thread is free again.');
      }),
      ('Rust abort', 'Native crash from Rust (SIGABRT).', () {
        _arm('native-abort');
        cert.abortNow();
      }),
      ('Segfault', 'Sends SIGSEGV to the app process.', () {
        _arm('segfault');
        Process.killPid(pid, ProcessSignal.sigsegv);
      }),
      ('Memory climb', 'Allocates 64 MB at a time until the jail stops the app.', _memoryClimb),
      ('Exit normally', 'SystemNavigator.pop: the app asks to close.', () {
        _arm('normal-exit');
        SystemNavigator.pop();
      }),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Crash lab')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(padding: const EdgeInsets.all(8), child: Text(_note)),
          for (final (title, what, run) in tests)
            Card(
              child: ListTile(
                title: Text(title),
                subtitle: Text(what),
                trailing: FilledButton.tonal(onPressed: run, child: const Text('Run')),
              ),
            ),
        ],
      ),
    );
  }
}
