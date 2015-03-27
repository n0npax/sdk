// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// VMOptions=--verbose-debug

import 'package:observatory/service_io.dart';
import 'package:unittest/unittest.dart';
import 'test_helper.dart';
import 'dart:async';

printSync() {  // Line 12
  print('sync');
}
printAsync() async {  // Line 15
  print('async');
}
printAsyncStar() async* {  // Line 18
  print('async*');
}
printSyncStar() sync* {  // Line 21
  print('sync*');
}

var testerReady = false;
testeeDo() {
  // We block here rather than allowing the isolate to enter the
  // paused-on-exit state before the tester gets a chance to set
  // the breakpoints because we need the event loop to remain
  // operational for the async bodies to run.
  print('testee waiting');
  while(!testerReady);

  printSync();
  var future = printAsync();
  var stream = printAsyncStar();
  var iterator = printSyncStar();

  print('middle');  // Line 39.

  future.then((v) => print(v));
  stream.toList();
  iterator.toList();
}

testAsync(Isolate isolate) async {
  await isolate.rootLib.load();
  var script = isolate.rootLib.scripts[0];

  var bp1 = await isolate.addBreakpoint(script, 12);
  expect(bp1, isNotNull);
  expect(bp1 is Breakpoint, isTrue);
  var bp2 = await isolate.addBreakpoint(script, 15);
  expect(bp2, isNotNull);
  expect(bp2 is Breakpoint, isTrue);
  var bp3 = await isolate.addBreakpoint(script, 18);
  expect(bp3, isNotNull);
  expect(bp3 is Breakpoint, isTrue);
  var bp4 = await isolate.addBreakpoint(script, 21);
  expect(bp4, isNotNull);
  expect(bp4 is Breakpoint, isTrue);
  var bp5 = await isolate.addBreakpoint(script, 39);
  expect(bp5, isNotNull);
  expect(bp5 is Breakpoint, isTrue);

  var hits = [];

  isolate.eval(isolate.rootLib, 'testerReady = true;')
      .then((Instance result) {
        expect(result.valueAsString, equals('true'));
      });

  await for (ServiceEvent event in isolate.vm.events.stream) {
    if (event.eventType == ServiceEvent.kPauseBreakpoint) {
      var bp = event.breakpoint;
      print('Hit $bp');
      hits.add(bp);
      isolate.resume();

      if (hits.length == 5) break;
    }
  }

  expect(hits, equals([bp1, bp5, bp4, bp2, bp3]));
}

var tests = [testAsync];

main(args) => runIsolateTests(args, tests, testeeConcurrent: testeeDo);
