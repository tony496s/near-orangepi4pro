import 'dart:io';

import 'package:flutter/services.dart';

/// Loads the bundled Be Vietnam Pro (and the NearMono log font) into the test engine. Without it, text is laid out
/// with the test font (every glyph 1 em wide, about twice as wide as the real font), so overflow checks would not match
/// the board.
Future<void> loadAppFonts() async {
  final files = Directory('fonts').listSync().whereType<File>().where((f) => f.path.endsWith('.ttf')).toList();
  for (final (family, prefix) in const [('BeVietnamPro', 'BeVietnamPro-'), ('NearMono', 'DejaVuSansMono')]) {
    final loader = FontLoader(family);
    for (final f in files.where((f) => f.uri.pathSegments.last.startsWith(prefix))) {
      loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(f.readAsBytesSync()))));
    }
    await loader.load();
  }
}
