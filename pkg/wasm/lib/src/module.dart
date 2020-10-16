// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'runtime.dart';
import 'function.dart';
import 'wasmer_api.dart';
import 'dart:typed_data';
import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// WasmModule is a compiled module that can be instantiated.
class WasmModule {
  Pointer<WasmerStore> _store;
  late Pointer<WasmerModule> _module;

  /// Compile a module.
  WasmModule(Uint8List data) : _store = WasmRuntime().newStore() {
    _module = WasmRuntime().compile(_store, data);
  }

  /// Returns a WasmInstanceBuilder that is used to add all the imports that the
  /// module needs, and then instantiate it.
  WasmInstanceBuilder instantiate() {
    return WasmInstanceBuilder(this);
  }

  /// Create a new memory with the given number of initial pages, and optional
  /// maximum number of pages.
  WasmMemory createMemory(int pages, [int? maxPages]) {
    return WasmMemory._create(_store, pages, maxPages);
  }

  /// Returns a description of all of the module's imports and exports, for
  /// debugging.
  String describe() {
    var description = StringBuffer();
    var runtime = WasmRuntime();
    var imports = runtime.importDescriptors(_module);
    for (var imp in imports) {
      description.write("import $imp\n");
    }
    var exports = runtime.exportDescriptors(_module);
    for (var exp in exports) {
      description.write("export $exp\n");
    }
    return description.toString();
  }
}

Pointer<WasmerTrap> _wasmFnImportTrampoline(Pointer<_WasmFnImport> imp,
    Pointer<WasmerVal> args, Pointer<WasmerVal> results) {
  try {
    _WasmFnImport._call(imp, args, results);
  } catch (e) {
    // TODO: Use WasmerTrap to handle this case. For now just print the
    // exception (if we ignore it, FFI will silently return a default result).
    print(e);
  }
  return nullptr;
}

void _wasmFnImportFinalizer(Pointer<_WasmFnImport> imp) {
  _wasmFnImportToFn.remove(imp.address);
  free(imp);
}

final _wasmFnImportTrampolineNative = Pointer.fromFunction<
    Pointer<WasmerTrap> Function(Pointer<_WasmFnImport>, Pointer<WasmerVal>,
        Pointer<WasmerVal>)>(_wasmFnImportTrampoline);
final _wasmFnImportToFn = <int, Function>{};
final _wasmFnImportFinalizerNative =
    Pointer.fromFunction<Void Function(Pointer<_WasmFnImport>)>(
        _wasmFnImportFinalizer);

class _WasmFnImport extends Struct {
  @Int32()
  external int numArgs;

  @Int32()
  external int returnType;

  static void _call(Pointer<_WasmFnImport> imp, Pointer<WasmerVal> rawArgs,
      Pointer<WasmerVal> rawResult) {
    Function fn = _wasmFnImportToFn[imp.address] as Function;
    var args = [];
    for (var i = 0; i < imp.ref.numArgs; ++i) {
      args.add(rawArgs[i].toDynamic);
    }
    var result = Function.apply(fn, args);
    switch (imp.ref.returnType) {
      case WasmerValKindI32:
        rawResult.ref.i32 = result;
        break;
      case WasmerValKindI64:
        rawResult.ref.i64 = result;
        break;
      case WasmerValKindF32:
        rawResult.ref.f32 = result;
        break;
      case WasmerValKindF64:
        rawResult.ref.f64 = result;
        break;
      case WasmerValKindVoid:
      // Do nothing.
    }
  }
}

/// WasmInstanceBuilder is used collect all the imports that a WasmModule
/// requires before it is instantiated.
class WasmInstanceBuilder {
  WasmModule _module;
  late List<WasmImportDescriptor> _importDescs;
  Map<String, int> _importIndex;
  late Pointer<Pointer<WasmerExtern>> _imports;

  WasmInstanceBuilder(this._module) : _importIndex = {} {
    _importDescs = WasmRuntime().importDescriptors(_module._module);
    _imports = allocate<Pointer<WasmerExtern>>(count: _importDescs.length);
    for (var i = 0; i < _importDescs.length; ++i) {
      var imp = _importDescs[i];
      _importIndex["${imp.moduleName}::${imp.name}"] = i;
      _imports[i] = nullptr;
    }
  }

  int _getIndex(String moduleName, String name) {
    var index = _importIndex["${moduleName}::${name}"];
    if (index == null) {
      throw Exception("Import not found: ${moduleName}::${name}");
    } else if (_imports[index] != nullptr) {
      throw Exception("Import already filled: ${moduleName}::${name}");
    } else {
      return index;
    }
  }

  /// Add a WasmMemory to the imports.
  WasmInstanceBuilder addMemory(
      String moduleName, String name, WasmMemory memory) {
    var index = _getIndex(moduleName, name);
    var imp = _importDescs[index];
    if (imp.kind != WasmerExternKindMemory) {
      throw Exception("Import is not a memory: $imp");
    }
    _imports[index] = WasmRuntime().memoryToExtern(memory._mem);
    return this;
  }

  /// Add a function to the imports.
  WasmInstanceBuilder addFunction(String moduleName, String name, Function fn) {
    var index = _getIndex(moduleName, name);
    var imp = _importDescs[index];
    var runtime = WasmRuntime();

    if (imp.kind != WasmerExternKindFunction) {
      throw Exception("Import is not a function: $imp");
    }

    var argTypes = runtime.getArgTypes(imp.funcType);
    var returnType = runtime.getReturnType(imp.funcType);
    var wasmFnImport = allocate<_WasmFnImport>();
    wasmFnImport.ref.numArgs = argTypes.length;
    wasmFnImport.ref.returnType = returnType;
    _wasmFnImportToFn[wasmFnImport.address] = fn;
    var fnImp = runtime.newFunc(
        _module._store,
        imp.funcType,
        _wasmFnImportTrampolineNative,
        wasmFnImport,
        _wasmFnImportFinalizerNative);
    _imports[index] = runtime.functionToExtern(fnImp);
    return this;
  }

  /// Build the module instance.
  WasmInstance build() {
    for (var i = 0; i < _importDescs.length; ++i) {
      if (_imports[i] == nullptr) {
        throw Exception("Missing import: ${_importDescs[i]}");
      }
    }
    return WasmInstance(_module, _imports);
  }
}

/// WasmInstance is an instantiated WasmModule.
class WasmInstance {
  WasmModule _module;
  Pointer<WasmerInstance> _instance;
  Pointer<WasmerMemory>? _exportedMemory;
  Map<String, WasmFunction> _functions = {};

  WasmInstance(this._module, Pointer<Pointer<WasmerExtern>> imports)
      : _instance = WasmRuntime()
            .instantiate(_module._store, _module._module, imports) {
    var runtime = WasmRuntime();
    var exports = runtime.exports(_instance);
    var exportDescs = runtime.exportDescriptors(_module._module);
    assert(exports.ref.length == exportDescs.length);
    for (var i = 0; i < exports.ref.length; ++i) {
      var e = exports.ref.data[i];
      var kind = runtime.externKind(exports.ref.data[i]);
      String name = exportDescs[i].name;
      if (kind == WasmerExternKindFunction) {
        var f = runtime.externToFunction(e);
        var ft = exportDescs[i].funcType;
        _functions[name] = WasmFunction(
            name, f, runtime.getArgTypes(ft), runtime.getReturnType(ft));
      } else if (kind == WasmerExternKindMemory) {
        // WASM currently allows only one memory per module.
        _exportedMemory = runtime.externToMemory(e);
      }
    }
  }

  /// Searches the instantiated module for the given function. Returns null if
  /// it is not found.
  dynamic lookupFunction(String name) {
    return _functions[name];
  }

  /// Returns the memory exported from this instance.
  WasmMemory get memory {
    if (_exportedMemory == null) {
      throw Exception("Wasm module did not export its memory.");
    }
    return WasmMemory._fromExport(_exportedMemory as Pointer<WasmerMemory>);
  }
}

/// WasmMemory contains the memory of a WasmInstance.
class WasmMemory {
  Pointer<WasmerMemory> _mem;
  late Uint8List _view;

  WasmMemory._fromExport(this._mem) {
    _view = WasmRuntime().memoryView(_mem);
  }

  /// Create a new memory with the given number of initial pages, and optional
  /// maximum number of pages.
  WasmMemory._create(Pointer<WasmerStore> store, int pages, int? maxPages)
      : _mem = WasmRuntime().newMemory(store, pages, maxPages) {
    _view = WasmRuntime().memoryView(_mem);
  }

  /// The WASM spec defines the page size as 64KiB.
  static const int kPageSizeInBytes = 64 * 1024;

  /// Returns the length of the memory in pages.
  int get lengthInPages {
    return WasmRuntime().memoryLength(_mem);
  }

  /// Returns the length of the memory in bytes.
  int get lengthInBytes => _view.lengthInBytes;

  /// Returns the byte at the given index.
  int operator [](int index) => _view[index];

  /// Sets the byte at the given index to value.
  void operator []=(int index, int value) {
    _view[index] = value;
  }

  /// Grow the memory by deltaPages.
  void grow(int deltaPages) {
    var runtime = WasmRuntime();
    runtime.growMemory(_mem, deltaPages);
    _view = runtime.memoryView(_mem);
  }
}
