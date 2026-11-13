import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// Opens the system share sheet for [files]. On iPad the sheet is a popover
/// and needs an anchor: the widget [context] belongs to (else the screen).
Future<void> shareFiles(BuildContext context, List<File> files, {required String subject}) {
  final box = context.findRenderObject();
  final Rect? origin = box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
  return Share.shareXFiles([for (final f in files) XFile(f.path)], subject: subject, sharePositionOrigin: origin);
}
