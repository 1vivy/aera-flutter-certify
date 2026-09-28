import 'package:flutter/material.dart';

import 'aera/runtime.dart';
import 'cert/crash_lab.dart';
import 'cert/metrics.dart';
import 'cert/report.dart';
import 'cert/suite.dart';

Future<void> main() async {
  Startup.mainToFirstFrame.start();
  Startup.atMain = processAgeSeconds();
  await initAera();
  runApp(const CertifyApp());
  WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
    Startup.mainToFirstFrame.stop();
    Startup.atFirstFrame = processAgeSeconds();
  });
}

class CertifyApp extends StatelessWidget {
  const CertifyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flutter Certify',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark)),
    home: const Home(),
  );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Report? _report;
  String? _path;
  int _run = 0;

  @override
  Widget build(BuildContext context) {
    final report = _report;
    if (report == null) {
      return Suite(
        key: ValueKey(_run),
        onDone: (report, path) => setState(() {
          _report = report;
          _path = path;
        }),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Certification report'),
        actions: [
          IconButton(
            tooltip: 'Crash lab',
            icon: const Icon(Icons.bug_report),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CrashLab())),
          ),
          IconButton(
            tooltip: 'Run again',
            icon: const Icon(Icons.replay),
            onPressed: () => setState(() {
              _report = null;
              _run++;
            }),
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            title: Text('${report.meta['flutterMode']} build, ${report.meta['renderer']} renderer, on ${(report.meta['host'] as Map)['label']}'),
            subtitle: Text('${report.meta['appVersion']} (${report.meta['appBuild']})\n'
                '${_path == null ? 'Report not saved' : 'Saved to $_path'}'),
          ),
          for (final r in report.results)
            ListTile(
              dense: true,
              leading: _Chip(r.grade),
              title: Text('${r.area}: ${r.name}'),
              subtitle: Text(r.summary),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.grade);
  final Grade grade;
  @override
  Widget build(BuildContext context) {
    final color = switch (grade) {
      Grade.a || Grade.pass => Colors.green,
      Grade.b => Colors.lightGreen,
      Grade.c => Colors.amber,
      Grade.f || Grade.fail => Colors.red,
      _ => Colors.blueGrey,
    };
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(6)),
      alignment: Alignment.center,
      child: Text(grade.label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
    );
  }
}
