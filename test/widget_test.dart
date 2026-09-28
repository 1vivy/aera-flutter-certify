import 'package:flutter_test/flutter_test.dart';

import 'package:aera_certify/cert/report.dart';

void main() {
  test('lower-is-better grades', () {
    expect(gradeBelow(10, 16.7, 33.4, 50), Grade.a);
    expect(gradeBelow(20, 16.7, 33.4, 50), Grade.b);
    expect(gradeBelow(40, 16.7, 33.4, 50), Grade.c);
    expect(gradeBelow(90, 16.7, 33.4, 50), Grade.f);
  });

  test('higher-is-better grades', () {
    expect(gradeAbove(60, 50, 15, 3), Grade.a);
    expect(gradeAbove(2, 50, 15, 3), Grade.f);
  });

  test('report serialises results', () {
    final report = Report({'host': 'pc'})..add(Result('frames', 'Idle', Grade.a, '60 fps', {'fps': 60}));
    final json = report.toJson();
    expect(json['format'], 'aera-flutter-cert/1');
    expect((json['results'] as List).single, containsPair('grade', 'A'));
  });
}
