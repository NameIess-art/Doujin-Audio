// CLI report output is intentional.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  // A real 30-minute idle interval exceeds integrationDriver's 20-minute default.
  timeout: Duration(
    seconds: int.parse(
      Platform.environment['PERF_DRIVER_TIMEOUT_SECONDS'] ?? '7200',
    ),
  ),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final report = data?['uiPerformance'];
    await writeResponseData(
      data,
      testOutputFilename: report is Map && report['scenario'] == 'playback'
          ? 'playback_profile_${report['runtime'] == 'Media3' ? 'android' : 'windows'}'
          : report is Map &&
                '${report['scenario']}'.startsWith('page-transitions')
          ? 'page_transitions_${report['platform']}_${report['scenario'] == 'page-transitions-startup'
                ? 'startup'
                : report['playing'] == true
                ? 'playing'
                : 'idle'}'
          : 'integration_response_data',
    );
    if (report is! Map || report['scenario'] != 'playback') return;
    print(
      'PLAYBACK_BASELINE ${report['baseline']}; '
      'pre-change profile available=${report['preChangeBaselineAvailable']}',
    );
    if (report['measurementStatus'] != 'complete') {
      print(
        'PLAYBACK_PROFILE incomplete: execution failed before all stages finished.',
      );
      return;
    }
    final gates = report['gates'];
    if (gates is! Map || gates['measurementValid'] != true) {
      print(
        'PLAYBACK_PROFILE unverified: a complete Profile-mode frame sample is required.',
      );
      return;
    }
    print(
      'PLAYBACK_PROFILE ${gates['allTargetsPassed'] == true ? 'PASS' : 'FAIL'}',
    );
    print(
      'PLAYBACK_BASELINE_BUDGET ${gates['baselineWithinBudget'] == true ? 'PASS' : 'OVER_BUDGET'}',
    );
    print(
      'PLAYBACK_IDLE_INCREMENT ${gates['idleSessionIncrementWithinBudget'] == true ? 'PASS' : 'REGRESSION'}',
    );
    print(
      'PLAYBACK_ALL_STAGE_BUDGET ${gates['allStagesWithinBudget'] == true ? 'PASS' : 'OVER_BUDGET'}',
    );
    print(
      'PLAYBACK_NEXT_FRAME_FEEDBACK ${gates['nextFrameIntentFeedbackObserved'] == true ? 'PASS' : 'FAIL'}',
    );
    print(
      'PLAYBACK_IDLE_60_SECONDS ${gates['idle60SecondsSilent'] == true ? 'PASS' : 'FAIL'}',
    );
    print('PLAYBACK_PERFORMANCE_GATES ${jsonEncode(gates)}');
  },
);
