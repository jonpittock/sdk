// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'common/service_test_common.dart';
import 'common/test_helper.dart';

// AUTOGENERATED START
//
// Update these constants by running:
//
// dart pkg/vm_service/test/update_line_numbers.dart <test.dart>
//
const LINE_A = 19;
// AUTOGENERATED END

const file = 'step_through_function_2_test.dart';

void code() /* LINE_A */ {
  Bar bar = Bar();
  bar.barXYZ1(42);
  bar.barXYZ2(42);
  fooXYZ1(42);
  fooXYZ2(42);
}

// ignore: unused_element
int _xyz = -1;

void fooXYZ1(int i) {
  _xyz = i - 1;
}

void fooXYZ2(int i) {
  _xyz = i;
}

class Bar {
  int _xyz = -1;

  void barXYZ1(int i) {
    _xyz = i - 1;
  }

  void barXYZ2(int i) {
    _xyz = i;
  }

  int get barXYZ => _xyz + 1;
}

final stops = <String>[];
const expected = <String>[
  '$file:${LINE_A + 0}:10', // after 'code'
  '$file:${LINE_A + 1}:13', // on 'Bar'

  '$file:${LINE_A + 2}:7', // on 'barXYZ1'
  '$file:${LINE_A + 22}:20', // on 'i'
  '$file:${LINE_A + 23}:14', // on '-'
  '$file:${LINE_A + 23}:5', // on '_xyz'
  '$file:${LINE_A + 24}:3', // on '}'

  '$file:${LINE_A + 3}:7', // on 'barXYZ2'
  '$file:${LINE_A + 26}:20', // on 'i'
  '$file:${LINE_A + 27}:5', // on '_xyz'
  '$file:${LINE_A + 28}:3', // on '}'

  '$file:${LINE_A + 4}:3', // on 'fooXYZ1'
  '$file:${LINE_A + 11}:18', // on 'i'
  '$file:${LINE_A + 12}:12', // on '-'
  '$file:${LINE_A + 13}:1', // on '}'

  '$file:${LINE_A + 5}:3', // on 'fooXYZ2'
  '$file:${LINE_A + 15}:18', // on 'i'
  '$file:${LINE_A + 16}:3', // on '_xyz'
  '$file:${LINE_A + 17}:1', // on '}'

  '$file:${LINE_A + 6}:1' // on ending '}'
];

final tests = <IsolateTest>[
  hasPausedAtStart,
  setBreakpointAtLine(LINE_A),
  runStepIntoThroughProgramRecordingStops(stops),
  checkRecordedStops(
    stops,
    expected,
    debugPrint: true,
    debugPrintFile: file,
    debugPrintLine: LINE_A,
  ),
];

void main([args = const <String>[]]) => runIsolateTests(
      args,
      tests,
      'step_through_function_2_test.dart',
      testeeConcurrent: code,
      pause_on_start: true,
      pause_on_exit: true,
    );
