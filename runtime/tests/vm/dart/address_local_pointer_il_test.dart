// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Verify that returning the address of a locally created Pointer that doesn't
// escape just returns the address used to create the Pointer without actually
// creating it. (See https://github.com/dart-lang/sdk/issues/53124.)

import 'dart:ffi';

import 'package:expect/expect.dart';
import 'package:ffi/ffi.dart';
import 'package:vm/testing/il_matchers.dart';

@pragma('vm:never-inline')
@pragma('vm:testing:print-flow-graph')
int identity(int address) => Pointer<Void>.fromAddress(address).address;

void matchIL$identity(FlowGraph graph) {
  graph.dump();
  graph.match([
    match.block('Graph'),
    match.block('Function', [
      'address' << match.Parameter(index: 0),
      match.Return('address'),
    ]),
  ]);
}

void main(List<String> args) {
  final n = args.isEmpty ? 100 : int.parse(args.first);
  Expect.equals(n, identity(n));
}
