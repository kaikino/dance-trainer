import 'package:flutter/material.dart';

import '../ble/protocol.dart';

/// How a session behaves. Capture and Dance are the node's modes; Practice and
/// Performance are both node mode `dance`, differing only in what the app does
/// on a mistake.
enum SessionKind { capture, performance, practice }

extension SessionKindX on SessionKind {
  Mode get nodeMode => this == SessionKind.capture ? Mode.capture : Mode.dance;
  String get title => switch (this) {
        SessionKind.capture => 'Capture',
        SessionKind.performance => 'Performance',
        SessionKind.practice => 'Practice',
      };
  String get description => switch (this) {
        SessionKind.capture => 'Record raw sensor data for training the step classifier',
        SessionKind.performance => 'Dance it straight through and get scored at the end.',
        SessionKind.practice => 'Stops on a wrong or missed step and goes back to the start of that bar.',
      };
  IconData get icon => switch (this) {
        SessionKind.practice => Icons.school_rounded,
        SessionKind.performance => Icons.emoji_events_rounded,
        SessionKind.capture => Icons.fiber_manual_record_rounded,
      };
}
