import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../src/rust/frb_generated.dart';

/// Loads the app's Rust library and starts flutter_rust_bridge.
///
/// Inside AERA the library sits at `/usr/lib/libaera_app_core.so` in the
/// app's payload. Under `aera-host-sim` on a PC the payload is not the root,
/// so the embedder passes its location in `AERA_FLUTTER_ROOT`. With
/// `flutter run -d linux` neither exists and flutter_rust_bridge's own
/// loader finds the library that cargokit built.
Future<void> initAera() async {
  final root = Platform.environment['AERA_FLUTTER_ROOT'] ?? '/';
  final bundled = File('$root/usr/lib/libaera_app_core.so');
  await RustLib.init(
    externalLibrary: bundled.existsSync()
        ? ExternalLibrary.open(bundled.path)
        : null,
  );
}
