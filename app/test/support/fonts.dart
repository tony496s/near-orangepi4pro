import 'dart:io';

import 'package:flutter/services.dart';

/// Loads the bundled Be Vietnam Pro into the test engine. Without it, text is laid out with the test font (every
/// glyph 1 em wide, about twice as wide as the real font), so overflow checks would not match the board.
Future<void> loadAppFonts() async {
  final loader = FontLoader('BeVietnamPro');
  for (final f in Directory('fonts').listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'))) {
    loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(f.readAsBytesSync()))));
  }
  await loader.load();
}
