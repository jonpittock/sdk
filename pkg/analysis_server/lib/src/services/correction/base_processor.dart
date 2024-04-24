// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server_plugin/edit/correction_utils.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/src/dart/analysis/session_helper.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_workspace.dart';

/// Base class for common processor functionality.
abstract class BaseProcessor {
  final int selectionOffset;
  final int selectionLength;
  final int selectionEnd;

  final CorrectionUtils utils;
  final String file;

  final TypeProvider typeProvider;

  final AnalysisSession session;
  final AnalysisSessionHelper sessionHelper;
  final ResolvedUnitResult resolvedResult;
  final ChangeWorkspace workspace;

  BaseProcessor({
    this.selectionOffset = -1,
    this.selectionLength = 0,
    required this.resolvedResult,
    required this.workspace,
  })  : file = resolvedResult.path,
        session = resolvedResult.session,
        sessionHelper = AnalysisSessionHelper(resolvedResult.session),
        typeProvider = resolvedResult.typeProvider,
        selectionEnd = selectionOffset + selectionLength,
        utils = CorrectionUtils(resolvedResult);

  AstNode? findSelectedNode() {
    var locator = NodeLocator(selectionOffset, selectionEnd);
    return locator.searchWithin(resolvedResult.unit);
  }
}
