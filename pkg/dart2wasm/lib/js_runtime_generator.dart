// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_js_interop_checks/src/js_interop.dart'
    show
        calculateTransitiveImportsOfJsInteropIfUsed,
        getJSName,
        hasAnonymousAnnotation,
        hasJSInteropAnnotation,
        hasObjectLiteralAnnotation,
        hasStaticInteropAnnotation;
import 'package:_js_interop_checks/src/transformations/js_util_optimizer.dart'
    show InlineExtensionIndex;
import 'package:_js_interop_checks/src/transformations/static_interop_class_eraser.dart';
import 'package:dart2wasm/js_runtime_blob.dart';
import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_environment.dart';

enum _AnnotationType { import, export }

enum _MethodType {
  jsObjectLiteralConstructor,
  constructor,
  getter,
  method,
  setter,
  operator,
}

bool parametersNeedParens(List<String> parameters) =>
    parameters.isEmpty || parameters.length > 1;

class _MethodLoweringConfig {
  final Procedure procedure;
  final _MethodType type;
  final String jsString;
  final StaticInvocation? invocation;
  final InlineExtensionIndex _inlineExtensionIndex;
  late final bool isConstructor =
      type == _MethodType.jsObjectLiteralConstructor ||
          type == _MethodType.constructor;
  late final bool firstParameterIsObject =
      _inlineExtensionIndex.isInstanceInteropMember(procedure);
  late final List<VariableDeclaration> parameters = _parameters;
  late final List<Expression> arguments = _arguments;

  _MethodLoweringConfig(this.procedure, this.type, this.jsString,
      this.invocation, this._inlineExtensionIndex);

  FunctionNode get function => procedure.function;
  Uri get fileUri => procedure.fileUri;

  // The parameters that determine arity (and key names in the case of object
  // literals) of the interop procedure that is created from this config.
  List<VariableDeclaration> get _parameters {
    if (type == _MethodType.jsObjectLiteralConstructor) {
      // Compute the parameters that were used in the given `invocation`. Note
      // that we preserve the procedure's ordering and not the invocations.
      Set<String> usedArgs =
          invocation!.arguments.named.map((expr) => expr.name).toSet();
      return function.namedParameters
          .where((decl) => usedArgs.contains(decl.name))
          .toList();
    }
    return function.positionalParameters;
  }

  // The arguments that will be passed into the interop procedure that is
  // created from this config.
  List<Expression> get _arguments {
    if (type == _MethodType.jsObjectLiteralConstructor) {
      // Return the args in the order of the procedure's parameters and not the
      // invocation.
      Map<String, Expression> namedArgs = {};
      for (NamedExpression expr in invocation!.arguments.named) {
        namedArgs[expr.name] = expr.value;
      }
      return parameters
          .map<Expression>((decl) => namedArgs[decl.name!]!)
          .toList();
    }
    return function.positionalParameters
        .map((decl) => VariableGet(decl))
        .toList();
  }

  String generateJS(List<String> parameterNames) {
    String object = isConstructor
        ? ''
        : firstParameterIsObject
            ? parameterNames[0]
            : 'globalThis';
    List<String> callArguments =
        firstParameterIsObject ? parameterNames.sublist(1) : parameterNames;
    String callArgumentsString = callArguments.join(',');
    String functionParameters = firstParameterIsObject
        ? '$object${callArguments.isEmpty ? '' : ',$callArgumentsString'}'
        : callArgumentsString;
    String bodyString;
    switch (type) {
      case _MethodType.jsObjectLiteralConstructor:
        List<String> keys = parameters.map((named) => named.name!).toList();
        List<String> keyValuePairs = [];
        for (int i = 0; i < parameterNames.length; i++) {
          keyValuePairs.add('${keys[i]}: ${parameterNames[i]}');
        }
        bodyString = '({${keyValuePairs.join(',')}})';
        break;
      case _MethodType.constructor:
        bodyString = 'new $jsString($callArgumentsString)';
        break;
      case _MethodType.getter:
        bodyString = '$object.$jsString';
        break;
      case _MethodType.method:
        bodyString = '$object.$jsString($callArgumentsString)';
        break;
      case _MethodType.setter:
        bodyString = '$object.$jsString = $callArgumentsString';
        break;
      case _MethodType.operator:
        if (jsString == '[]') {
          bodyString = '$object[${callArguments[0]}]';
        } else if (jsString == '[]=') {
          bodyString = '$object[${callArguments[0]}] = ${callArguments[1]}';
        } else {
          throw 'Unsupported operator: $jsString';
        }
        break;
    }
    if (parametersNeedParens(parameterNames)) {
      return '($functionParameters) => $bodyString';
    } else {
      return '$functionParameters => $bodyString';
    }
  }
}

/// Lowers static interop to JS, generating specialized JS methods as required.
/// We lower methods to JS, but wait to emit the runtime until after we complete
/// translation. Ideally, we'd do everything after translation, but
/// unfortunately the TFA assumes classes with external factory constructors
/// that aren't mark with `entry-point` are abstract, and their methods thus get
/// replaced with `throw`s. Since we have to lower factory methods anyways, we
/// go ahead and lower everything, let the TFA tree shake, and then emit JS only
/// for the remaining nodes. We can revisit this if it becomes a performance
/// issue.
/// TODO(joshualitt): Only support JS types in static interop APIs, then
/// simpify this code significantly and clean up the nullabilities.
class _JSLowerer extends Transformer {
  final Procedure _dartifyRawTarget;
  final Procedure _jsifyRawTarget;
  final Procedure _isDartFunctionWrappedTarget;
  final Procedure _wrapDartFunctionTarget;
  final Procedure _jsObjectFromDartObjectTarget;
  final Procedure _jsValueBoxTarget;
  final Procedure _jsValueUnboxTarget;
  final Procedure _allowInteropTarget;
  final Procedure _functionToJSTarget;
  final Procedure _inlineJSTarget;
  final Procedure _numToIntTarget;
  final Constructor _jsValueConstructor;
  final Class _wasmExternRefClass;
  final Class _pragmaClass;
  final Field _pragmaName;
  final Field _pragmaOptions;
  bool _replaceProcedureWithInlineJS = false;
  late String _inlineJSImportName;
  final Map<Procedure, String> jsMethods = {};
  int _methodN = 1;
  late Library _library;
  late String _libraryJSString;
  final Map<Procedure, Map<String, Procedure>> _jsObjectLiteralMethods = {};

  final CoreTypes _coreTypes;
  late InlineExtensionIndex _inlineExtensionIndex;
  final StatefulStaticTypeContext _staticTypeContext;

  _JSLowerer(this._coreTypes, ClassHierarchy hierarchy)
      : _dartifyRawTarget = _coreTypes.index
            .getTopLevelProcedure('dart:_js_helper', 'dartifyRaw'),
        _jsifyRawTarget = _coreTypes.index
            .getTopLevelProcedure('dart:_js_helper', 'jsifyRaw'),
        _isDartFunctionWrappedTarget = _coreTypes.index
            .getTopLevelProcedure('dart:_js_helper', '_isDartFunctionWrapped'),
        _wrapDartFunctionTarget = _coreTypes.index
            .getTopLevelProcedure('dart:_js_helper', '_wrapDartFunction'),
        _jsObjectFromDartObjectTarget = _coreTypes.index
            .getTopLevelProcedure('dart:_js_helper', 'jsObjectFromDartObject'),
        _jsValueConstructor = _coreTypes.index
            .getClass('dart:_js_helper', 'JSValue')
            .constructors
            .single,
        _jsValueBoxTarget = _coreTypes.index
            .getClass('dart:_js_helper', 'JSValue')
            .procedures
            .firstWhere((p) => p.name.text == 'box'),
        _jsValueUnboxTarget = _coreTypes.index
            .getClass('dart:_js_helper', 'JSValue')
            .procedures
            .firstWhere((p) => p.name.text == 'unbox'),
        _allowInteropTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', 'allowInterop'),
        _inlineJSTarget =
            _coreTypes.index.getTopLevelProcedure('dart:_js_helper', 'JS'),
        _wasmExternRefClass =
            _coreTypes.index.getClass('dart:wasm', 'WasmExternRef'),
        _numToIntTarget = _coreTypes.index
            .getClass('dart:core', 'num')
            .procedures
            .firstWhere((p) => p.name.text == 'toInt'),
        _functionToJSTarget = _coreTypes.index.getTopLevelProcedure(
            'dart:js_interop', 'FunctionToJSExportedDartFunction|get#toJS'),
        _pragmaClass = _coreTypes.pragmaClass,
        _pragmaName = _coreTypes.pragmaName,
        _pragmaOptions = _coreTypes.pragmaOptions,
        _staticTypeContext = StatefulStaticTypeContext.stacked(
            TypeEnvironment(_coreTypes, hierarchy)) {}

  @override
  Library visitLibrary(Library lib) {
    _library = lib;
    _inlineExtensionIndex = InlineExtensionIndex(_library);
    _libraryJSString = getJSName(_library);
    if (_libraryJSString.isNotEmpty) {
      _libraryJSString = '$_libraryJSString.';
    }
    _staticTypeContext.enterLibrary(lib);
    lib.transformChildren(this);
    _staticTypeContext.leaveLibrary(lib);
    return lib;
  }

  @override
  Member defaultMember(Member node) {
    _staticTypeContext.enterMember(node);
    node.transformChildren(this);
    _staticTypeContext.leaveMember(node);
    return node;
  }

  @override
  Expression visitStaticInvocation(StaticInvocation node) {
    node = super.visitStaticInvocation(node) as StaticInvocation;
    if (node.target == _allowInteropTarget) {
      Expression argument = node.arguments.positional.single;
      DartType functionType = argument.getStaticType(_staticTypeContext);
      return _allowInterop(node.target, functionType as FunctionType, argument);
    } else if (node.target == _functionToJSTarget) {
      Expression argument = node.arguments.positional.single;
      DartType functionType = argument.getStaticType(_staticTypeContext);
      return _functionToJS(node.target, functionType as FunctionType, argument);
    } else if (node.target == _inlineJSTarget) {
      return _expandInlineJS(node.target, node);
    } else if ((node.target.isInlineClassMember &&
            node.target.isExternal &&
            hasObjectLiteralAnnotation(node.target)) ||
        (node.target.isFactory &&
            node.target.isExternal &&
            hasAnonymousAnnotation(node.target.enclosingClass!))) {
      assert(node.arguments.positional.isEmpty);
      return _specializeJSMethod(_MethodLoweringConfig(
          node.target,
          _MethodType.jsObjectLiteralConstructor,
          '',
          node,
          _inlineExtensionIndex));
    }
    return node;
  }

  String _getJSString(Annotatable a, String initial) {
    String selectorString = getJSName(a);
    if (selectorString.isEmpty) {
      selectorString = initial;
    }
    return selectorString;
  }

  String _getTopLevelJSString(Annotatable a, String initial) =>
      '$_libraryJSString${_getJSString(a, initial)}';

  _MethodType _getTypeForNonExtensionMember(Procedure node) {
    if (node.isGetter) {
      return _MethodType.getter;
    } else if (node.isSetter) {
      return _MethodType.setter;
    } else {
      assert(node.kind == ProcedureKind.Method);
      return _MethodType.method;
    }
  }

  _MethodType _getTypeForInlineClassMember(InlineClassMemberKind kind) {
    if (kind == InlineClassMemberKind.Getter) {
      return _MethodType.getter;
    } else if (kind == InlineClassMemberKind.Setter) {
      return _MethodType.setter;
    } else {
      assert(kind == InlineClassMemberKind.Method);
      return _MethodType.method;
    }
  }

  @override
  Procedure visitProcedure(Procedure node) {
    _staticTypeContext.enterMember(node);
    Statement? transformedBody;
    if (node.isExternal) {
      _MethodType? type;
      String jsString = '';
      if (node.enclosingClass != null &&
          hasJSInteropAnnotation(node.enclosingClass!)) {
        Class cls = node.enclosingClass!;
        jsString = _getTopLevelJSString(cls, cls.name);
        if (node.isFactory) {
          if (!hasAnonymousAnnotation(cls)) type = _MethodType.constructor;
        } else {
          String memberSelectorString = _getJSString(node, node.name.text);
          jsString = '$jsString.$memberSelectorString';
          type = _getTypeForNonExtensionMember(node);
        }
      } else if (node.isInlineClassMember) {
        InlineClassMemberDescriptor? nodeDescriptor =
            _inlineExtensionIndex.getInlineDescriptor(node.reference);
        if (nodeDescriptor != null) {
          InlineClass cls =
              _inlineExtensionIndex.getInlineClass(node.reference)!;
          InlineClassMemberKind kind = nodeDescriptor.kind;
          jsString = _getTopLevelJSString(cls, cls.name);
          if ((kind == InlineClassMemberKind.Constructor ||
                  kind == InlineClassMemberKind.Factory) &&
              !hasObjectLiteralAnnotation(node)) {
            type = _MethodType.constructor;
          } else if (nodeDescriptor.isStatic) {
            String memberSelectorString =
                _getJSString(node, nodeDescriptor.name.text);
            jsString = '$jsString.$memberSelectorString';
            type = _getTypeForInlineClassMember(kind);
          } else {
            jsString = _getJSString(node, nodeDescriptor.name.text);
            if (_inlineExtensionIndex.isGetter(node)) {
              type = _MethodType.getter;
            } else if (_inlineExtensionIndex.isSetter(node)) {
              type = _MethodType.setter;
            } else if (_inlineExtensionIndex.isMethod(node)) {
              type = _MethodType.method;
            } else if (_inlineExtensionIndex.isOperator(node)) {
              type = _MethodType.operator;
            }
          }
        }
      } else if (node.isExtensionMember) {
        ExtensionMemberDescriptor? nodeDescriptor =
            _inlineExtensionIndex.getExtensionDescriptor(node.reference);
        if (nodeDescriptor != null) {
          if (!nodeDescriptor.isStatic) {
            jsString = _getJSString(node, nodeDescriptor.name.text);
            if (_inlineExtensionIndex.isGetter(node)) {
              type = _MethodType.getter;
            } else if (_inlineExtensionIndex.isSetter(node)) {
              type = _MethodType.setter;
            } else if (_inlineExtensionIndex.isMethod(node)) {
              type = _MethodType.method;
            } else if (_inlineExtensionIndex.isOperator(node)) {
              type = _MethodType.operator;
            }
          }
        }
      } else if (hasJSInteropAnnotation(node)) {
        jsString = _getTopLevelJSString(node, node.name.text);
        type = _getTypeForNonExtensionMember(node);
      }
      if (type != null) {
        Expression invocation = _specializeJSMethod(_MethodLoweringConfig(
            node, type, jsString, null, _inlineExtensionIndex));
        transformedBody = node.function.returnType is VoidType
            ? ExpressionStatement(invocation)
            : ReturnStatement(invocation);
      }
    }
    if (transformedBody != null) {
      node.function.body = transformedBody..parent = node.function;
      node.isExternal = false;
    } else {
      // Under very restricted circumstances, we will make a procedure external
      // and clear it's body. See the description on [_expandInlineJS] for more
      // details.
      _replaceProcedureWithInlineJS = false;
      node.transformChildren(this);
      if (_replaceProcedureWithInlineJS) {
        node.isStatic = true;
        node.isExternal = true;
        node.function.body = null;
        _annotateProcedure(node, _inlineJSImportName, _AnnotationType.import);
        _replaceProcedureWithInlineJS = false;
      }
    }
    _staticTypeContext.leaveMember(node);
    return node;
  }

  bool _isStaticInteropType(DartType type) =>
      (type is InterfaceType &&
          hasStaticInteropAnnotation(type.className.asClass)) ||
      (type is InlineType && hasJSInteropAnnotation(type.inlineClass));

  // We could generate something more human readable, but for now we just
  // generate something short and unique.
  String generateMethodName() => '_${_methodN++}';

  DartType get _nonNullableObjectType =>
      _coreTypes.objectRawType(Nullability.nonNullable);

  DartType get _nullableWasmExternRefType =>
      _wasmExternRefClass.getThisType(_coreTypes, Nullability.nullable);

  DartType get _nonNullableWasmExternRefType =>
      _wasmExternRefClass.getThisType(_coreTypes, Nullability.nonNullable);

  Expression _variableCheckConstant(
          VariableDeclaration variable, Constant constant) =>
      StaticInvocation(_coreTypes.identicalProcedure,
          Arguments([VariableGet(variable), ConstantExpression(constant)]));

  Procedure _jsifyTarget(DartType type) {
    if (_isStaticInteropType(type)) {
      return _jsValueUnboxTarget;
    } else {
      return _jsifyRawTarget;
    }
  }

  void _annotateProcedure(
      Procedure procedure, String pragmaOptionString, _AnnotationType type) {
    String pragmaName;
    switch (type) {
      case _AnnotationType.import:
        pragmaName = 'import';
        break;
      case _AnnotationType.export:
        pragmaName = 'export';
        break;
    }
    procedure.addAnnotation(
        ConstantExpression(InstanceConstant(_pragmaClass.reference, [], {
      _pragmaName.fieldReference: StringConstant('wasm:$pragmaName'),
      _pragmaOptions.fieldReference: StringConstant('$pragmaOptionString')
    })));
  }

  Procedure _addInteropProcedure(String name, String pragmaOptionString,
      FunctionNode function, Uri fileUri, _AnnotationType type,
      {required bool isExternal}) {
    final procedure = Procedure(
        Name(name, _library), ProcedureKind.Method, function,
        isStatic: true, isExternal: isExternal, fileUri: fileUri)
      ..isNonNullableByDefault = true;
    _annotateProcedure(procedure, pragmaOptionString, type);
    _library.addProcedure(procedure);
    return procedure;
  }

  StaticInvocation _invokeOneArg(Procedure target, Expression arg) =>
      StaticInvocation(target, Arguments([arg]));

  Statement _generateDispatchCase(
      FunctionType function,
      VariableDeclaration callbackVariable,
      List<VariableDeclaration> positionalParameters,
      int requiredParameterCount,
      {required bool boxExternRef}) {
    List<Expression> callbackArguments = [];
    for (int i = 0; i < requiredParameterCount; i++) {
      DartType callbackParameterType = function.positionalParameters[i];
      Expression expression;
      VariableGet v = VariableGet(positionalParameters[i]);
      if (_isStaticInteropType(callbackParameterType) && boxExternRef) {
        expression = _createJSValue(v);
      } else {
        expression = AsExpression(
            _invokeOneArg(_dartifyRawTarget, v), callbackParameterType);
      }
      callbackArguments.add(expression);
    }
    return ReturnStatement(StaticInvocation(
        _jsifyTarget(function.returnType),
        Arguments([
          FunctionInvocation(
              FunctionAccessKind.FunctionType,
              AsExpression(VariableGet(callbackVariable), function),
              Arguments(callbackArguments),
              functionType: function),
        ])));
  }

  bool _needsArgumentsLength(FunctionType type) =>
      type.requiredParameterCount < type.positionalParameters.length;

  /// Creates a callback trampoline for the given [function]. This callback
  /// trampoline expects a Dart callback as its first argument, then an integer
  /// value(double type) indicating the position of the last defined
  /// argument(only for callbacks that take optional parameters), followed by
  /// all of the arguments to the Dart callback as JS objects.  The trampoline
  /// will `dartifyRaw` all incoming JS objects and then cast them to their
  /// appropriate types, dispatch, and then `jsifyRaw` any returned value.
  /// [_createFunctionTrampoline] Returns a [String] function name representing
  /// the name of the wrapping function.
  String _createFunctionTrampoline(Procedure node, FunctionType function,
      {required bool boxExternRef}) {
    // Create arguments for each positional parameter in the function. These
    // arguments will be JS objects. The generated wrapper will cast each
    // argument to the correct type.  The first argument to this function will
    // be the Dart callback, which will be cast to the supplied [FunctionType]
    // before being invoked. If the callback takes optional parameters then, the
    // second argument will be a `double` indicating the last defined argument.
    int parameterId = 1;
    final callbackVariable =
        VariableDeclaration('callback', type: _nonNullableObjectType);
    VariableDeclaration? argumentsLength;
    if (_needsArgumentsLength(function)) {
      argumentsLength = VariableDeclaration('argumentsLength',
          type: _coreTypes.doubleNonNullableRawType);
    }

    // Initialize variable declarations.
    List<VariableDeclaration> positionalParameters = [];
    for (int j = 0; j < function.positionalParameters.length; j++) {
      positionalParameters.add(VariableDeclaration('x${parameterId++}',
          type: _nullableWasmExternRefType));
    }

    // Build the body of a function trampoline. To support default arguments, we
    // find the last defined argument in JS, that is the last argument which was
    // explicitly passed by the user, and then we dispatch to a Dart function
    // with the right number of arguments.
    //
    // First we handle cases where some or all arguments are undefined.
    // TODO(joshualitt): Consider using a switch instead.
    List<Statement> dispatchCases = [];
    for (int i = function.requiredParameterCount + 1;
        i <= function.positionalParameters.length;
        i++) {
      dispatchCases.add(IfStatement(
          _variableCheckConstant(
              argumentsLength!, DoubleConstant(i.toDouble())),
          _generateDispatchCase(
              function, callbackVariable, positionalParameters, i,
              boxExternRef: boxExternRef),
          null));
    }

    // Finally handle the case where only required parameters are passed.
    dispatchCases.add(_generateDispatchCase(function, callbackVariable,
        positionalParameters, function.requiredParameterCount,
        boxExternRef: boxExternRef));
    Statement functionTrampolineBody = Block(dispatchCases);

    // Create a new procedure for the callback trampoline. This procedure will
    // be exported from Wasm to JS so it can be called from JS. The argument
    // returned from the supplied callback will be converted with `jsifyRaw` to
    // a native JS value before being returned to JS.
    final functionTrampolineName = generateMethodName();
    _addInteropProcedure(
        functionTrampolineName,
        functionTrampolineName,
        FunctionNode(functionTrampolineBody,
            positionalParameters: [
              callbackVariable,
              if (argumentsLength != null) argumentsLength
            ].followedBy(positionalParameters).toList(),
            returnType: _nullableWasmExternRefType)
          ..fileOffset = node.fileOffset,
        node.fileUri,
        _AnnotationType.export,
        isExternal: false);
    return functionTrampolineName;
  }

  /// Returns a JS method that wraps a Dart callback in a JS wrapper.
  Procedure _getJSWrapperFunction(
      FunctionType type, String functionTrampolineName, Uri fileUri) {
    List<String> jsParameters = [];
    for (int i = 0; i < type.positionalParameters.length; i++) {
      jsParameters.add('x$i');
    }
    String jsParametersString = jsParameters.join(',');
    String dartArguments = 'f';
    bool needsArguments = _needsArgumentsLength(type);
    if (needsArguments) {
      dartArguments = '$dartArguments,arguments.length';
    }
    if (jsParameters.isNotEmpty) {
      dartArguments = '$dartArguments,$jsParametersString';
    }

    // Create Dart procedure stub.
    final jsMethodName = functionTrampolineName;
    Procedure dartProcedure = _addInteropProcedure(
        '|$jsMethodName',
        'dart2wasm.$jsMethodName',
        FunctionNode(null,
            positionalParameters: [
              VariableDeclaration('dartFunction',
                  type: _nonNullableWasmExternRefType)
            ],
            returnType: _nonNullableWasmExternRefType),
        fileUri,
        _AnnotationType.import,
        isExternal: true);

    // Create JS method.
    // Note: We have to use a regular function for the inner closure in some
    // cases because we need access to `arguments`.
    if (needsArguments) {
      jsMethods[dartProcedure] = "$jsMethodName: f => "
          "finalizeWrapper(f, function($jsParametersString) {"
          " return dartInstance.exports.$functionTrampolineName($dartArguments) "
          "})";
    } else {
      if (parametersNeedParens(jsParameters)) {
        jsParametersString = '($jsParametersString)';
      }
      jsMethods[dartProcedure] = "$jsMethodName: f => "
          "finalizeWrapper(f,$jsParametersString => "
          "dartInstance.exports.$functionTrampolineName($dartArguments))";
    }

    return dartProcedure;
  }

  /// Lowers an invocation of `allowInterop<type>(foo)` to:
  ///
  ///   let #var = foo in
  ///     _isDartFunctionWrapped<type>(#var) ?
  ///       #var :
  ///       _wrapDartFunction<type>(#var, jsWrapperFunction(#var));
  ///
  /// The use of two functions here is necessary because we do not allow
  /// `WasmExternRef` to be an argument or return type for a tear off.
  ///
  /// Note: _wrapDartFunction tracks wrapped Dart functions in a map.  When
  /// these Dart functions flow to JS, they are replaced by their wrappers.  If
  /// the wrapper should ever flow back into Dart then it will be replaced by
  /// the original Dart function.
  Expression _allowInterop(
      Procedure node, FunctionType type, Expression argument) {
    String functionTrampolineName =
        _createFunctionTrampoline(node, type, boxExternRef: false);
    Procedure jsWrapperFunction =
        _getJSWrapperFunction(type, functionTrampolineName, node.fileUri);
    VariableDeclaration v =
        VariableDeclaration('#var', initializer: argument, type: type);
    return Let(
        v,
        ConditionalExpression(
            StaticInvocation(_isDartFunctionWrappedTarget,
                Arguments([VariableGet(v)], types: [type])),
            VariableGet(v),
            StaticInvocation(
                _wrapDartFunctionTarget,
                Arguments([
                  VariableGet(v),
                  StaticInvocation(
                      jsWrapperFunction,
                      Arguments([
                        StaticInvocation(_jsObjectFromDartObjectTarget,
                            Arguments([VariableGet(v)]))
                      ])),
                ], types: [
                  type
                ])),
            type));
  }

  Expression _createJSValue(Expression value) =>
      ConstructorInvocation(_jsValueConstructor, Arguments([value]));

  /// Lowers an invocation of `<Function>.toJS` to:
  ///
  ///   JSValue(jsWrapperFunction(<Function>))
  Expression _functionToJS(
      Procedure node, FunctionType type, Expression argument) {
    String functionTrampolineName =
        _createFunctionTrampoline(node, type, boxExternRef: true);
    Procedure jsWrapperFunction =
        _getJSWrapperFunction(type, functionTrampolineName, node.fileUri);
    return _createJSValue(StaticInvocation(
        jsWrapperFunction,
        Arguments([
          StaticInvocation(_jsObjectFromDartObjectTarget, Arguments([argument]))
        ])));
  }

  InstanceInvocation _invokeMethod(
          VariableDeclaration receiver, Procedure target) =>
      InstanceInvocation(InstanceAccessKind.Instance, VariableGet(receiver),
          target.name, Arguments([]),
          interfaceTarget: target,
          functionType:
              target.function.computeFunctionType(Nullability.nonNullable));

  /// Creates a Dart procedure that calls out to a specialized JS method for the
  /// given [config] and returns the created procedure.
  Procedure _getInteropProcedure(_MethodLoweringConfig config) {
    // Initialize variable declarations.
    List<String> jsParameterStrings = [];
    List<VariableDeclaration> originalParameters = config.parameters;
    List<VariableDeclaration> dartPositionalParameters = [];
    for (int j = 0; j < originalParameters.length; j++) {
      String parameterString = 'x$j';
      dartPositionalParameters.add(VariableDeclaration(parameterString,
          type: _nullableWasmExternRefType));
      jsParameterStrings.add(parameterString);
    }

    // Create Dart procedure stub for JS method.
    String jsMethodName = generateMethodName();
    final dartProcedure = _addInteropProcedure(
        '|$jsMethodName',
        'dart2wasm.$jsMethodName',
        FunctionNode(null,
            positionalParameters: dartPositionalParameters,
            returnType: _nullableWasmExternRefType),
        config.fileUri,
        _AnnotationType.import,
        isExternal: true);

    // Create JS method
    jsMethods[dartProcedure] =
        "$jsMethodName: ${config.generateJS(jsParameterStrings)}";

    return dartProcedure;
  }

  /// Specializes a JS method for a given [config] and returns an invocation of
  /// the specialized method.
  Expression _specializeJSMethod(_MethodLoweringConfig config) {
    Procedure interopProcedure;
    if (config.type == _MethodType.jsObjectLiteralConstructor) {
      // To avoid one method for every invocation, we optimize and compute one
      // method per invocation shape. For example, `Cons(a: 0, b: 0)`,
      // `Cons(a: 0)`, and `Cons(a: 1, b: 1)` only create two shapes:
      // `{a: value, b: value}` and `{a: value}`. Therefore, we only need two
      // methods to handle the `Cons` invocations.
      String shape = config.parameters
          .map((VariableDeclaration decl) => decl.name)
          .join('|');
      _jsObjectLiteralMethods
          .putIfAbsent(config.procedure, () => {})
          .putIfAbsent(shape, () => _getInteropProcedure(config));
      interopProcedure = _jsObjectLiteralMethods[config.procedure]![shape]!;
    } else {
      interopProcedure = _getInteropProcedure(config);
    }
    // Return the replacement body.
    // Because we simply don't have enough information, we leave all JS numbers
    // as doubles. However, in cases where we know the user expects an `int` we
    // insert a cast. We also let static interop types flow through without
    // conversion, both as arguments, and as the return type.
    DartType returnType = config.function.returnType;
    List<Expression> positionalArgs = config.arguments
        .map((expr) => StaticInvocation(
            _jsifyTarget(expr.getStaticType(_staticTypeContext)),
            Arguments([expr])))
        .toList();
    Expression invocation =
        StaticInvocation(interopProcedure, Arguments(positionalArgs));
    DartType returnTypeOverride = returnType == _coreTypes.intNullableRawType
        ? _coreTypes.doubleNullableRawType
        : returnType == _coreTypes.intNonNullableRawType
            ? _coreTypes.doubleNonNullableRawType
            : returnType;
    if (returnType is! VoidType) {
      if (_isStaticInteropType(returnType)) {
        // TODO(joshualitt): Expose boxed `JSNull` and `JSUndefined` to Dart
        // code after migrating existing users of js interop on Dart2Wasm.
        // invocation = _createJSValue(invocation);
        invocation = _invokeOneArg(_jsValueBoxTarget, invocation);
      } else {
        invocation = AsExpression(
            _convertReturnType(returnType, returnTypeOverride,
                _invokeOneArg(_dartifyRawTarget, invocation)),
            returnType);
      }
    }
    return invocation;
  }

  // Handles any necessary return type conversions. Today this is just for
  // handling the case where a user wants us to coerce a JS number to an int
  // instead of a double.
  Expression _convertReturnType(
      DartType returnType, DartType returnTypeOverride, Expression expression) {
    if (returnType == _coreTypes.intNullableRawType ||
        returnType == _coreTypes.intNonNullableRawType) {
      VariableDeclaration v = VariableDeclaration('#var',
          initializer: expression, type: returnTypeOverride);
      return Let(
          v,
          ConditionalExpression(
              _variableCheckConstant(v, NullConstant()),
              ConstantExpression(NullConstant()),
              _invokeMethod(v, _numToIntTarget),
              returnType));
    } else {
      return expression;
    }
  }

  Procedure? _tryGetEnclosingProcedure(TreeNode? node) {
    while (node is! Procedure) {
      node = node?.parent;
      if (node == null) {
        return null;
      }
    }
    return node;
  }

  /// We will replace the enclosing procedure if:
  ///   1) The enclosing procedure is static.
  ///   2) The enclosing procedure has a body with a single statement, and that
  ///      statement is just a [StaticInvocation] of the inline JS helper.
  ///   3) All of the arguments to `inlineJS` are [VariableGet]s. (this is
  ///      checked by [_expandInlineJS]).
  bool _shouldReplaceEnclosingProcedure(StaticInvocation node) {
    Procedure? enclosingProcedure = _tryGetEnclosingProcedure(node);
    if (enclosingProcedure == null) {
      return false;
    }
    Statement enclosingBody = enclosingProcedure.function.body!;
    Expression? expression;
    if (enclosingBody is ReturnStatement) {
      expression = enclosingBody.expression;
    } else if (enclosingBody is Block && enclosingBody.statements.length == 1) {
      Statement statement = enclosingBody.statements.single;
      if (statement is ExpressionStatement) {
        expression = statement.expression;
      } else if (statement is ReturnStatement) {
        expression = statement.expression;
      }
    }
    return expression == node;
  }

  /// Calls to the `JS` helper are replaced in one of two ways:
  ///   1) By a static invocation to an external stub method that imports
  ///      the JS function.
  ///   2) Under restricted circumstances the entire enclosing procedure will be
  ///      replaced by an external stub method that imports the JS function. See
  ///      [_shouldReplaceEnclosingProcedure] for more details.
  Expression _expandInlineJS(Procedure inlineJSNode, StaticInvocation node) {
    Arguments arguments = node.arguments;
    List<Expression> originalArguments = arguments.positional.sublist(1);
    List<VariableDeclaration> dartPositionalParameters = [];
    bool allArgumentsAreGet = true;
    for (int j = 0; j < originalArguments.length; j++) {
      Expression originalArgument = originalArguments[j];
      String parameterString = 'x$j';
      DartType type = originalArgument.getStaticType(_staticTypeContext);
      dartPositionalParameters
          .add(VariableDeclaration(parameterString, type: type));
      if (originalArgument is! VariableGet) {
        allArgumentsAreGet = false;
      }
    }

    assert(arguments.positional[0] is StringLiteral,
        "Code template must be a StringLiteral");
    String codeTemplate = (arguments.positional[0] as StringLiteral).value;
    String jsMethodName = generateMethodName();
    _inlineJSImportName = 'dart2wasm.$jsMethodName';
    _replaceProcedureWithInlineJS =
        allArgumentsAreGet && _shouldReplaceEnclosingProcedure(node);
    Procedure dartProcedure;
    Expression result;
    if (_replaceProcedureWithInlineJS) {
      dartProcedure = _tryGetEnclosingProcedure(node)!;
      result = InvalidExpression("Unreachable");
    } else {
      dartProcedure = _addInteropProcedure(
          '|$jsMethodName',
          _inlineJSImportName,
          FunctionNode(null,
              positionalParameters: dartPositionalParameters,
              returnType: arguments.types.single),
          inlineJSNode.fileUri,
          _AnnotationType.import,
          isExternal: true);
      result = StaticInvocation(dartProcedure, Arguments(originalArguments));
    }
    jsMethods[dartProcedure] = "$jsMethodName: $codeTemplate";
    return result;
  }
}

Map<Procedure, String> _performJSInteropTransformations(
    Component component,
    CoreTypes coreTypes,
    ClassHierarchy classHierarchy,
    Set<Library> interopDependentLibraries) {
  final jsLowerer = _JSLowerer(coreTypes, classHierarchy);
  for (Library library in interopDependentLibraries) {
    jsLowerer.visitLibrary(library);
  }

  // We want static types to help us specialize methods based on receivers.
  // Therefore, erasure must come after the lowering.
  final staticInteropClassEraser = StaticInteropClassEraser(coreTypes, null,
      libraryForJavaScriptObject: 'dart:_js_helper',
      classNameOfJavaScriptObject: 'JSValue',
      additionalCoreLibraries: {'_js_helper', '_js_types', 'js_interop'});
  for (Library library in interopDependentLibraries) {
    staticInteropClassEraser.visitLibrary(library);
  }
  return jsLowerer.jsMethods;
}

class JSRuntimeFinalizer {
  final Map<Procedure, String> allJSMethods;

  JSRuntimeFinalizer(this.allJSMethods);

  String generate(Iterable<Procedure> translatedProcedures) {
    Set<Procedure> usedProcedures = {};
    List<String> usedJSMethods = [];
    for (Procedure p in translatedProcedures) {
      if (usedProcedures.add(p) && allJSMethods.containsKey(p)) {
        usedJSMethods.add(allJSMethods[p]!);
      }
    }
    return '''
  $jsRuntimeBlobPart1
  ${usedJSMethods.join(',\n')}
  $jsRuntimeBlobPart2
''';
  }
}

JSRuntimeFinalizer createJSRuntimeFinalizer(
    Component component, CoreTypes coreTypes, ClassHierarchy classHierarchy) {
  Set<Library> transitiveImportingJSInterop = {
    ...?calculateTransitiveImportsOfJsInteropIfUsed(
        component, Uri.parse("package:js/js.dart")),
    ...?calculateTransitiveImportsOfJsInteropIfUsed(
        component, Uri.parse("dart:_js_annotations")),
    ...?calculateTransitiveImportsOfJsInteropIfUsed(
        component, Uri.parse("dart:_js_helper")),
  };
  Map<Procedure, String> jsInteropMethods = {};
  jsInteropMethods = _performJSInteropTransformations(
      component, coreTypes, classHierarchy, transitiveImportingJSInterop);
  return JSRuntimeFinalizer(jsInteropMethods);
}
