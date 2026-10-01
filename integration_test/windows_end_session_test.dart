import 'dart:io';

import 'package:doujin_audio/core/platform/windows_desktop_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  registerWindowsEndSessionTest();
}

void registerWindowsEndSessionTest() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows end-session waits for a channel reply without closing',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(() async {
        const response = String.fromEnvironment(
          'END_SESSION_RESPONSE',
          defaultValue: 'success',
        );
        var requests = 0;
        await WindowsDesktopService.instance.attach((action) async {
          if (action != 'endSession') return;
          requests++;
          if (response == 'timeout') {
            await Future<void>.delayed(const Duration(seconds: 5));
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 150));
            if (response == 'error') {
              throw StateError('simulated cleanup failure');
            }
          }
        });
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$testProcessId = $pid\n"
              r'''
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EndSessionTest {
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr window, StringBuilder name, int size);
  public delegate bool Enumerate(IntPtr window, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Enumerate callback, IntPtr data);
  public static IntPtr OwnedWindow(uint target) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((window, data) => {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      var name = new StringBuilder(256);
      GetClassNameW(window, name, name.Capacity);
      if (owner == target && name.ToString().StartsWith("DOUJIN_AUDIO_WIN32_WINDOW")) { found = window; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@
$window = [EndSessionTest]::OwnedWindow($testProcessId)
if ($window -eq [IntPtr]::Zero) { throw 'Test window missing' }
$owner = [uint32]0
[void][EndSessionTest]::GetWindowThreadProcessId($window, [ref]$owner)
if ($owner -ne $testProcessId) { throw 'Window is owned by another process; refusing to send messages' }
$query = [EndSessionTest]::SendMessageW($window, 0x11, [IntPtr]::Zero, [IntPtr]::Zero)
if ($query -ne [IntPtr]1) { throw 'Query rejected' }
[void][EndSessionTest]::SendMessageW($window, 0x16, [IntPtr]::Zero, [IntPtr]::Zero)
$watch = [Diagnostics.Stopwatch]::StartNew()
[void][EndSessionTest]::SendMessageW($window, 0x16, [IntPtr]1, [IntPtr]::Zero)
$watch.Stop()
$watch.ElapsedMilliseconds
[void][EndSessionTest]::SendMessageW($window, 0x16, [IntPtr]1, [IntPtr]::Zero)
''',
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final elapsed = int.parse((result.stdout as String).trim());
        expect(requests, 1);
        expect(
          elapsed,
          greaterThanOrEqualTo(response == 'timeout' ? 3900 : 140),
        );
        expect(elapsed, lessThan(4800));
        // The Flutter engine must survive the wait, including a late timeout reply.
        if (response == 'timeout') {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        await WindowsDesktopService.instance.getHotkeyStatus();
      });
    },
    skip: !Platform.isWindows,
  );
}
