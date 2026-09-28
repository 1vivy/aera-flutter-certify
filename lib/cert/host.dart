import 'dart:io';

/// What the app is running under. Everything the suite assumes about the
/// browser slot lives here, so results from the generic pixel + GPU host can
/// be compared line by line once AERA ships it.
class HostProfile {
  const HostProfile({
    required this.id,
    required this.label,
    required this.hasBrowserChrome,
    required this.readbackCopy,
  });

  /// `aera-browser-slot`, `aera-pixel-host` or `pc`.
  final String id;
  final String label;

  /// AERA draws its address bar and dock over the app (browser slot only).
  final bool hasBrowserChrome;

  /// Every frame is copied from the GPU into shared memory by the embedder.
  final bool readbackCopy;

  static HostProfile detect() {
    final env = Platform.environment;
    final root = env['AERA_FLUTTER_ROOT'] ?? '/';
    final gpu = File('/dev/kgsl-3d0').existsSync();
    if (env['AERA_HOST'] == 'pixel') {
      return const HostProfile(
        id: 'aera-pixel-host',
        label: 'AERA pixel + GPU host',
        hasBrowserChrome: false,
        readbackCopy: true,
      );
    }
    if (File('/usr/bin/aera-browser-worker').existsSync() && gpu) {
      return const HostProfile(
        id: 'aera-browser-slot',
        label: 'AERA browser slot',
        hasBrowserChrome: true,
        readbackCopy: true,
      );
    }
    if (root != '/') {
      return const HostProfile(
        id: 'pc-sim',
        label: 'PC simulator (aera-host-sim)',
        hasBrowserChrome: false,
        readbackCopy: true,
      );
    }
    return const HostProfile(
      id: 'pc',
      label: 'PC (flutter run)',
      hasBrowserChrome: false,
      readbackCopy: false,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'hasBrowserChrome': hasBrowserChrome,
    'readbackCopy': readbackCopy,
  };
}
