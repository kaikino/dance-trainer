import 'package:flutter/widgets.dart';

/// Tells a screen when another one covers it and when it is in front again
/// (RouteAware), however the screens on top were pushed, replaced or popped.
/// The routine screen uses it to play its preview music only while it is the
/// screen you see.
final appRouteObserver = RouteObserver<ModalRoute<dynamic>>();
