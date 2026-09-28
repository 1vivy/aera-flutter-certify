import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../src/rust/api/aera.dart' as aera;
import '../src/rust/api/cert.dart' as cert;

import 'report.dart';

/// Checks that need no screen time: the jail's environment, storage,
/// network, fonts, isolates and the Rust bridge.
Future<List<Result>> runProbes({required bool quick}) async {
  final results = <Result>[];
  Future<void> guard(String area, String name, Future<Result> Function() probe) async {
    try {
      results.add(await probe());
    } catch (error) {
      results.add(Result(area, name, Grade.fail, 'threw: $error'));
    }
  }

  await guard('bridge', 'Dart to Rust call', _rustRoundTrip);
  await guard('bridge', 'Rust panic is caught', _rustPanic);
  await guard('compute', 'Rust threads', _rustThreads);
  await guard('compute', 'Rust fractal 360x700', _rustFractal);
  await guard('compute', 'Dart isolate', _isolate);
  final dirs = aera.storageDirs();
  for (final (label, path) in [('profile', dirs.appData), ('downloads', dirs.downloads), ('tmp', dirs.temp)]) {
    await guard('storage', '$label write/read', () => _storage(label, path, quick ? 8 : 32));
  }
  await guard('network', 'DNS lookup', _dns);
  await guard('network', 'TCP connect', _tcp);
  await guard('network', 'HTTPS request', _https);
  for (final (script, sample) in [
    ('Latin', 'Ag'),
    ('Cyrillic', 'Жж'),
    ('Greek', 'Ωω'),
    ('CJK', '中文'),
    ('Arabic', 'عربى'),
    ('Devanagari', 'हिन्दी'),
    ('Emoji', '😀'),
  ]) {
    await guard('text', 'glyphs: $script', () => _glyphs(script, sample));
  }
  await guard('platform', 'time zone', _timeZone);
  await guard('platform', 'clipboard', _clipboard);
  await guard('platform', 'renderer', _renderer);
  await guard('audio', 'speaker tone', _audio);
  return results;
}

Future<Result> _rustRoundTrip() async {
  const calls = 20000;
  final watch = Stopwatch()..start();
  var value = 0;
  for (var i = 0; i < calls; i++) {
    value = cert.ping(value: value);
  }
  final micros = watch.elapsedMicroseconds / calls;
  return Result('bridge', 'Dart to Rust call', value == calls ? gradeBelow(micros, 5, 20, 100) : Grade.fail,
      '${micros.toStringAsFixed(2)} µs per synchronous call', {'microsPerCall': micros});
}

Future<Result> _rustPanic() async {
  try {
    await cert.panicNow();
    return Result('bridge', 'Rust panic is caught', Grade.fail, 'panic did not reach Dart');
  } catch (error) {
    return Result('bridge', 'Rust panic is caught', Grade.pass, 'Dart received ${error.runtimeType}; app kept running');
  }
}

Future<Result> _rustThreads() async {
  final cpus = Platform.numberOfProcessors;
  const iterations = 20000000;
  final one = (await cert.spinThreads(threads: 1, iterations: BigInt.from(iterations))).toInt();
  final all = (await cert.spinThreads(threads: cpus, iterations: BigInt.from(iterations))).toInt();
  // Perfect scaling keeps the elapsed time flat as threads are added.
  final scaling = one * cpus / all;
  return Result('compute', 'Rust threads', gradeAbove(scaling / cpus, 0.6, 0.35, 0.2),
      '${scaling.toStringAsFixed(1)}x speed-up on $cpus CPUs',
      {'cpus': cpus, 'oneThreadUs': one, 'allThreadsUs': all, 'speedup': scaling});
}

Future<Result> _rustFractal() async {
  final watch = Stopwatch()..start();
  final pixels = await cert.fractal(
      width: 360, height: 700, centerX: -0.6, centerY: 0, scale: 3, maxIterations: 256);
  final ms = watch.elapsedMilliseconds;
  final ok = pixels.length == 360 * 700 * 4;
  return Result('compute', 'Rust fractal 360x700', ok ? gradeBelow(ms, 60, 150, 400) : Grade.fail,
      '$ms ms including the copy into Dart', {'ms': ms});
}

int _busy(int n) {
  var x = 1;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
  }
  return x;
}

Future<Result> _isolate() async {
  final watch = Stopwatch()..start();
  await Isolate.run(() => _busy(10));
  final spawnMs = watch.elapsedMilliseconds;
  watch.reset();
  await Isolate.run(() => _busy(20000000));
  final workMs = watch.elapsedMilliseconds;
  return Result('compute', 'Dart isolate', gradeBelow(spawnMs, 50, 150, 500),
      'spawn $spawnMs ms, 20M-step loop $workMs ms', {'spawnMs': spawnMs, 'workMs': workMs});
}

Future<Result> _storage(String label, String path, int megabytes) async {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    return Result('storage', '$label write/read', Grade.fail, '$path does not exist');
  }
  final file = File('$path/.aera-cert-${DateTime.now().microsecondsSinceEpoch}');
  final chunk = Uint8List(1024 * 1024);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = i & 0xff;
  }
  try {
    final watch = Stopwatch()..start();
    final out = await file.open(mode: FileMode.write);
    for (var i = 0; i < megabytes; i++) {
      await out.writeFrom(chunk);
    }
    await out.flush(); // fsync
    await out.close();
    final writeMs = watch.elapsedMilliseconds;
    watch.reset();
    final input = await file.open();
    var read = 0;
    var intact = true;
    final buffer = Uint8List(chunk.length);
    while (true) {
      final n = await input.readInto(buffer);
      if (n == 0) break;
      read += n;
      if (buffer[12345] != chunk[12345]) intact = false;
    }
    await input.close();
    final readMs = watch.elapsedMilliseconds;
    final writeMBs = megabytes * 1000 / writeMs.clamp(1, 1 << 30);
    final readMBs = megabytes * 1000 / readMs.clamp(1, 1 << 30);
    final ok = intact && read == megabytes * chunk.length;
    return Result('storage', '$label write/read', ok ? gradeAbove(writeMBs, 50, 15, 3) : Grade.fail,
        '$path: write ${writeMBs.toStringAsFixed(0)} MB/s, read ${readMBs.toStringAsFixed(0)} MB/s',
        {'path': path, 'megabytes': megabytes, 'writeMBs': writeMBs, 'readMBs': readMBs});
  } finally {
    if (file.existsSync()) await file.delete();
  }
}

Future<Result> _dns() async {
  final watch = Stopwatch()..start();
  final addresses = await InternetAddress.lookup('example.com').timeout(const Duration(seconds: 5));
  return Result('network', 'DNS lookup', addresses.isEmpty ? Grade.fail : Grade.pass,
      'example.com → ${addresses.first.address} in ${watch.elapsedMilliseconds} ms');
}

Future<Result> _tcp() async {
  final watch = Stopwatch()..start();
  final socket = await Socket.connect('1.1.1.1', 443, timeout: const Duration(seconds: 5));
  socket.destroy();
  return Result('network', 'TCP connect', Grade.pass, '1.1.1.1:443 in ${watch.elapsedMilliseconds} ms');
}

Future<Result> _https() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final watch = Stopwatch()..start();
    final request = await client.getUrl(Uri.parse('https://example.com/')).timeout(const Duration(seconds: 8));
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>();
    return Result('network', 'HTTPS request', response.statusCode == 200 ? Grade.pass : Grade.fail,
        'HTTP ${response.statusCode} in ${watch.elapsedMilliseconds} ms (TLS roots found)');
  } on HandshakeException catch (error) {
    return Result('network', 'HTTPS request', Grade.fail, 'TLS failed, likely no CA certificates in the jail: $error');
  } finally {
    client.close(force: true);
  }
}

/// Draws [text] and a private-use character (which no font covers) and
/// compares pixels. Identical images mean [text] also fell back to the
/// missing-glyph box.
Future<Uint8List> _draw(String text) async {
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 48))
    ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFFFFFFF)))
    ..addText(text);
  final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: 400));
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawParagraph(paragraph, ui.Offset.zero);
  final image = await recorder.endRecording().toImage(400, 80);
  final bytes = await image.toByteData();
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<Result> _glyphs(String script, String sample) async {
  final missing = await _draw(String.fromCharCodes(List.filled(sample.runes.length, 0xE000)));
  final drawn = await _draw(sample);
  var same = missing.length == drawn.length;
  for (var i = 0; same && i < drawn.length; i++) {
    if (missing[i] != drawn[i]) same = false;
  }
  final blank = drawn.every((b) => b == 0);
  final ok = !same && !blank;
  return Result('text', 'glyphs: $script', ok ? Grade.pass : Grade.fail,
      ok ? '"$sample" renders' : '"$sample" shows missing-glyph boxes; the runtime ships no font for $script');
}

Future<Result> _timeZone() async {
  final now = DateTime.now();
  final zone = now.timeZoneName;
  return Result('platform', 'time zone', Grade.info,
      'local zone $zone (offset ${now.timeZoneOffset.inMinutes} min); UTC means /etc/localtime is missing',
      {'zone': zone, 'offsetMinutes': now.timeZoneOffset.inMinutes});
}

Future<Result> _clipboard() async {
  try {
    await Clipboard.setData(const ClipboardData(text: 'aera-cert'));
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final ok = data?.text == 'aera-cert';
    return Result('platform', 'clipboard', ok ? Grade.pass : Grade.fail,
        ok ? 'copy and paste inside the app work' : 'the embedder does not keep clipboard text');
  } catch (error) {
    return Result('platform', 'clipboard', Grade.fail, 'not implemented by the embedder ($error)');
  }
}

Future<Result> _renderer() async {
  final impeller = ui.ImageFilter.isShaderFilterSupported;
  return Result('platform', 'renderer', Grade.info, impeller ? 'Impeller' : 'Skia',
      {'impeller': impeller});
}

Future<Result> _audio() async {
  final watch = Stopwatch()..start();
  try {
    await aera.playTone(frequencyHz: 880, milliseconds: 120, volume: 0.15);
    return Result('audio', 'speaker tone', Grade.pass, 'bridge took 120 ms of audio in ${watch.elapsedMilliseconds} ms');
  } catch (error) {
    final grade = aera.inRecovery() ? Grade.fail : Grade.skipped;
    return Result('audio', 'speaker tone', grade, 'no audio bridge: $error');
  }
}
