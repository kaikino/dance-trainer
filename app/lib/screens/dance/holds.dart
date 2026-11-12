part of 'dance_session.dart';

/// Why the music is stopped mid-session, and what the overlay offers. Each
/// carries the bar start that playback resumes from.
sealed class Hold {
  const Hold(this.fromBeat);
  final double fromBeat;

  /// Practice coaching (shown beside the chart); the others cover it.
  bool get coaching => this is MistakeHold || this is ChoiceHold;
}

/// Practice: a mistake, shown for a moment before the rewind.
class MistakeHold extends Hold {
  const MistakeHold(this.verdict, this.title, this.detail, super.fromBeat, this.nextTry);
  final Verdict verdict;
  final String title, detail;
  final int nextTry;
}

/// Practice: the bar failed too often; slow down or move on.
class ChoiceHold extends Hold {
  const ChoiceHold(super.fromBeat);
}

/// The app went to the background or the music was interrupted.
class PausedHold extends Hold {
  const PausedHold(this.reason, super.fromBeat);
  final String reason;
}

/// Restarting after a hold failed.
class FailedHold extends Hold {
  const FailedHold(this.message, super.fromBeat);
  final String message;
}
