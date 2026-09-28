import 'dart:convert';
import 'dart:io';

/// How a measured value compares with the certification thresholds.
enum Grade { a, b, c, f, pass, fail, info, skipped }

extension GradeText on Grade {
  String get label => switch (this) {
    Grade.a => 'A',
    Grade.b => 'B',
    Grade.c => 'C',
    Grade.f => 'F',
    Grade.pass => 'PASS',
    Grade.fail => 'FAIL',
    Grade.info => 'INFO',
    Grade.skipped => 'SKIP',
  };
  bool get bad => this == Grade.f || this == Grade.fail;
}

/// Lower is better: A up to [a], B up to [b], C up to [c], F beyond.
Grade gradeBelow(num value, num a, num b, num c) {
  if (value <= a) return Grade.a;
  if (value <= b) return Grade.b;
  if (value <= c) return Grade.c;
  return Grade.f;
}

/// Higher is better.
Grade gradeAbove(num value, num a, num b, num c) {
  if (value >= a) return Grade.a;
  if (value >= b) return Grade.b;
  if (value >= c) return Grade.c;
  return Grade.f;
}

class Result {
  Result(this.area, this.name, this.grade, this.summary, [this.data = const {}]);

  final String area;
  final String name;
  final Grade grade;
  final String summary;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'area': area,
    'name': name,
    'grade': grade.label,
    'summary': summary,
    if (data.isNotEmpty) 'data': data,
  };
}

class Report {
  Report(this.meta);

  final Map<String, Object?> meta;
  final List<Result> results = [];

  void add(Result result) => results.add(result);

  Map<String, Object?> toJson() => {
    'format': 'aera-flutter-cert/1',
    ...meta,
    'results': [for (final r in results) r.toJson()],
  };

  /// Writes the report as JSON and returns its path.
  Future<String> save(String directory) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '').split('.').first;
    final file = File('$directory/aera-cert-$stamp.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
    await File('$directory/aera-cert-latest.json').writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
    return file.path;
  }
}
