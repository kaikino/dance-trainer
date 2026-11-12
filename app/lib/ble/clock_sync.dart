import 'dart:async';

/// Clock maths between the app (wall clock, ms since epoch) and a node (a u32
/// microsecond counter that wraps every 2^32 µs, about 71.6 minutes).
///
/// The node offset is `t_node_us − t_app_us` at sync time. Node timestamps are
/// only ever compared with a nearby app time, through the signed difference
/// modulo 2^32, so a wrap between the sync and the strike does not matter.

const _u32 = 0x100000000;

/// a − b on the u32 µs clock, as a signed value in [−2^31, 2^31).
int u32DeltaUs(int a, int b) {
  final d = (a - b) & 0xffffffff;
  return d >= 0x80000000 ? d - _u32 : d;
}

/// Milliseconds after app time [refAppMs] at which node time [tNodeUs]
/// happened, for a node with [offsetUs]. Negative before it. Valid while the
/// two are within about 35 minutes of each other.
double nodeMsAfter(int tNodeUs, int refAppMs, int offsetUs) =>
    u32DeltaUs(tNodeUs, refAppMs * 1000 + offsetUs) / 1000.0;

/// One time-sync exchange: request sent at [sentMs], reply with the node's
/// clock [nodeUs] received at [receivedMs] (app ms).
typedef SyncSample = ({int sentMs, int nodeUs, int receivedMs});

/// No time-sync round got a reply.
class TimeSyncFailed implements Exception {
  const TimeSyncFailed(this.rounds);
  final int rounds;
  @override
  String toString() => 'The node did not answer the clock sync ($rounds tries). Move closer and try again.';
}

/// Runs [rounds] exchanges and returns the offset (node µs − app µs) from the
/// one with the shortest round trip, assuming the node read its clock halfway.
/// A round that times out (a lost notification) is skipped; this only fails
/// when none succeed.
Future<int> estimateOffset(Future<SyncSample> Function() exchange, {int rounds = 8}) async {
  int? best, bestRtt;
  for (var i = 0; i < rounds; i++) {
    final SyncSample s;
    try {
      s = await exchange();
    } on TimeoutException {
      continue;
    }
    final rtt = s.receivedMs - s.sentMs;
    if (bestRtt == null || rtt < bestRtt) {
      bestRtt = rtt;
      best = s.nodeUs - (s.sentMs * 1000 + rtt * 500);
    }
  }
  if (best == null) throw TimeSyncFailed(rounds);
  return best;
}
