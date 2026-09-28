import 'dart:convert';
import 'dart:io';

import '../src/rust/api/aera.dart' as aera;

/// What the previous launch left behind in private storage, so the suite can
/// tell a clean exit from a crash and check that `/profile` persists.
class RunState {
  RunState(this.runs, this.status);

  int runs;

  /// `running`, `finished`, or `crash-test:<kind>` written just before a
  /// deliberate crash.
  String status;

  static File get _file => File('${aera.storageDirs().appData}/aera-cert-state.json');

  static RunState load() {
    try {
      final json = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      return RunState(json['runs'] as int, json['status'] as String);
    } catch (_) {
      return RunState(0, 'none');
    }
  }

  void save() {
    try {
      _file.writeAsStringSync(jsonEncode({'runs': runs, 'status': status}), flush: true);
    } catch (_) {}
  }
}
