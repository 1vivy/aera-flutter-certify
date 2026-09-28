import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../src/rust/api/cert.dart' as cert;



/// A continuously animating screen the suite measures frame times on.
class Scene {
  const Scene(this.id, this.title, this.what, this.build);

  final String id;
  final String title;
  final String what;
  final Widget Function() build;
}

final scenes = <Scene>[
  Scene('idle', 'Idle clock', 'one small repaint per frame: the floor cost of a frame (GPU readback included)', () => const _Clock()),
  Scene('scroll', 'List scrolling', '2000 Material list tiles scrolled continuously', () => const _Scroll()),
  Scene('particles', 'Canvas particles', '3000 moving circles drawn with CustomPaint', () => const _Particles()),
  Scene('blur', 'Blur and gradients', 'rotating gradients under a full-width backdrop blur', () => const _Blur()),
  Scene('text', 'Text layout', '60 paragraphs re-laid out every frame', () => const _Text()),
  Scene('upload', 'Image upload', 'a new 360x700 image from Rust uploaded to the GPU every frame', () => const _Upload()),
  Scene('routes', 'Page transitions', 'a page pushed and popped every 450 ms', () => const _Routes()),
];

/// Rebuilds [builder] every frame with the elapsed time in seconds.
class _Animated extends StatefulWidget {
  const _Animated(this.builder);
  final Widget Function(BuildContext, double) builder;
  @override
  State<_Animated> createState() => _AnimatedState();
}

class _AnimatedState extends State<_Animated> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) => setState(() => _t = elapsed.inMicroseconds / 1e6))..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _t);
}

class _Clock extends StatelessWidget {
  const _Clock();
  @override
  Widget build(BuildContext context) => _Animated(
    (context, t) => Center(
      child: Text(t.toStringAsFixed(2), style: Theme.of(context).textTheme.displayMedium),
    ),
  );
}

class _Scroll extends StatefulWidget {
  const _Scroll();
  @override
  State<_Scroll> createState() => _ScrollState();
}

class _ScrollState extends State<_Scroll> with SingleTickerProviderStateMixin {
  final _controller = ScrollController();
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (!_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      _controller.jumpTo((elapsed.inMicroseconds / 1e6 * 1200) % max);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: _controller,
    itemCount: 2000,
    itemBuilder: (context, i) => ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.primaries[i % Colors.primaries.length],
        child: Text('${i % 100}'),
      ),
      title: Text('Item $i: partition ${['boot', 'system', 'vendor', 'userdata'][i % 4]}'),
      subtitle: Text('${(i * 37) % 4096} MB · checksum ${(i * 2654435761) & 0xffffff}'),
      trailing: Icon(i.isEven ? Icons.check_circle : Icons.pending),
    ),
  );
}

class _Particles extends StatelessWidget {
  const _Particles();
  @override
  Widget build(BuildContext context) =>
      _Animated((context, t) => CustomPaint(painter: _ParticlePainter(t), size: Size.infinite));
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var i = 0; i < 3000; i++) {
      final a = i * 2.39996 + t * (0.2 + (i % 7) * 0.05);
      final r = (i % 300) / 300 * size.shortestSide * 0.6;
      paint.color = HSVColor.fromAHSV(0.8, (i * 0.12 + t * 40) % 360, 0.7, 1).toColor();
      canvas.drawCircle(size.center(Offset(math.cos(a) * r, math.sin(a) * r * 1.6)), 2.5 + i % 4, paint);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.t != t;
}

class _Blur extends StatelessWidget {
  const _Blur();
  @override
  Widget build(BuildContext context) => _Animated(
    (context, t) => Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < 6; i++)
          Transform.rotate(
            angle: t * (0.3 + i * 0.1),
            child: Container(
              margin: EdgeInsets.all(20.0 + i * 25),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                gradient: SweepGradient(colors: [Colors.primaries[i], Colors.primaries[i + 6], Colors.primaries[i]]),
              ),
            ),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: const SizedBox(height: 350, width: double.infinity),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Text extends StatelessWidget {
  const _Text();
  @override
  Widget build(BuildContext context) => _Animated(
    (context, t) => ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 60; i++)
          Text(
            'Line $i · ${(t * 1000 + i * 7919).toStringAsFixed(0)} · flashing slot ${String.fromCharCode(65 + (t * 10 + i).floor() % 26)}',
            style: TextStyle(fontSize: 10.0 + i % 9, fontWeight: FontWeight.values[i % 9]),
          ),
      ],
    ),
  );
}

class _Upload extends StatefulWidget {
  const _Upload();
  @override
  State<_Upload> createState() => _UploadState();
}

class _UploadState extends State<_Upload> with SingleTickerProviderStateMixin {
  final List<Uint8List> _frames = [];
  late final Ticker _ticker;
  ui.Image? _image;
  bool _decoding = false;
  int _n = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _next());
    () async {
      for (final scale in [3.0, 2.2]) {
        _frames.add(await cert.fractal(
            width: 360, height: 700, centerX: -0.6, centerY: 0, scale: scale, maxIterations: 128));
      }
      if (mounted) _ticker.start();
    }();
  }

  void _next() {
    if (_decoding || _frames.isEmpty) return;
    _decoding = true;
    ui.decodeImageFromPixels(_frames[_n++ % _frames.length], 360, 700, ui.PixelFormat.rgba8888, (image) {
      _decoding = false;
      if (!mounted) return image.dispose();
      setState(() {
        _image?.dispose();
        _image = image;
      });
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _image == null ? const SizedBox.expand() : RawImage(image: _image, fit: BoxFit.cover, width: double.infinity, height: double.infinity);
}

class _Routes extends StatefulWidget {
  const _Routes();
  @override
  State<_Routes> createState() => _RoutesState();
}

class _RoutesState extends State<_Routes> {
  final _navigator = GlobalKey<NavigatorState>();
  bool _running = true;

  @override
  void initState() {
    super.initState();
    () async {
      var i = 0;
      while (_running) {
        await Future<void>.delayed(const Duration(milliseconds: 450));
        if (!_running) break;
        final nav = _navigator.currentState;
        if (nav == null) continue;
        if (nav.canPop()) {
          nav.pop();
        } else {
          i++;
          nav.push(MaterialPageRoute<void>(builder: (_) => _Page(i)));
        }
      }
    }();
  }

  @override
  void dispose() {
    _running = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Navigator(
    key: _navigator,
    onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const _Page(0)),
  );
}

class _Page extends StatelessWidget {
  const _Page(this.n);
  final int n;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.primaries[n % Colors.primaries.length].shade900,
    appBar: AppBar(title: Text('Page $n')),
    body: GridView.count(
      crossAxisCount: 3,
      children: [for (var i = 0; i < 18; i++) Card(child: Center(child: Icon(Icons.folder, size: 40 + (i % 3) * 8.0)))],
    ),
  );
}
