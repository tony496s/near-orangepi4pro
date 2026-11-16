import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../domain/intent/en_parser.dart' show englishExamples;
import '../../domain/intent/parser.dart' show examples;
import '../theme.dart';
import 'buttons.dart';

/// Covers the strip while listening and while showing what was heard. Tap to finish talking, or to close.
class ListeningOverlay extends StatelessWidget {
  const ListeningOverlay({super.key, required this.listening, required this.onTap});
  final Listening listening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = listening;
    final en = l.lang == 'en';
    final (label, color) = switch (l.phase) {
      ListenPhase.listening => (en ? 'ĐANG NGHE · TIẾNG ANH' : 'ĐANG NGHE', Ink.cool),
      ListenPhase.thinking => ('ĐANG HIỂU…', Ink.cool),
      ListenPhase.heard => ('ĐÃ NGHE', Ink.cool),
      ListenPhase.notUnderstood => ('CHƯA HIỂU', Ink.hot),
      ListenPhase.noSpeech => ('KHÔNG NGHE RÕ', Ink.hot),
      ListenPhase.unavailable => ('GIỌNG NÓI CHƯA SẴN SÀNG', Ink.hot),
    };
    final body = switch (l.phase) {
      ListenPhase.listening when en => 'Say a command, e.g. “set a timer for 25 minutes”',
      ListenPhase.listening => 'Nói lệnh, ví dụ “hẹn giờ 25 phút để tập trung”',
      ListenPhase.thinking => '',
      ListenPhase.heard => '“${l.text}”',
      ListenPhase.notUnderstood => '“${l.text}”',
      ListenPhase.noSpeech => 'Chạm nút mic rồi nói lại',
      ListenPhase.unavailable when en => 'Lệnh tiếng Anh cần mạng · thử lại, hoặc chạm VI để nói tiếng Việt',
      ListenPhase.unavailable => 'Đang khởi động, trong lúc chờ vẫn dùng chạm được',
    };
    final hint = switch (l.phase) {
      ListenPhase.listening => 'Ngừng nói là tự gửi · chạm để gửi ngay',
      ListenPhase.notUnderstood => 'Thử: ${(en ? englishExamples : examples).join(' · ')}',
      _ => '',
    };
    return GestureDetector(
      key: const Key('listening'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ColoredBox(
        color: const Color(0xC7030609),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (l.phase == ListenPhase.listening || l.phase == ListenPhase.thinking) ...[
                    _Bars(level: l.phase == ListenPhase.listening ? l.level : -60),
                    const SizedBox(width: 14),
                  ],
                  Text(label, style: ts(18, weight: FontWeight.w600, color: color, spacing: 18 * .22)),
                ],
              ),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 80),
                  child: Text(body,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(l.phase == ListenPhase.listening ? 24 : 42, weight: FontWeight.w500, color: l.phase == ListenPhase.listening ? Ink.dim : Ink.ink)),
                ),
              ],
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(18)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Five bars whose height follows the input level (-60..-10 dBFS).
class _Bars extends StatelessWidget {
  const _Bars({required this.level});
  final double level;

  static const _shape = [.55, .8, 1.0, .8, .55];

  @override
  Widget build(BuildContext context) {
    final k = ((level + 60) / 50).clamp(0.0, 1.0);
    return SizedBox(
      height: 34,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final s in _shape)
            AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              width: 6,
              height: 8 + 26 * k * s,
              decoration: BoxDecoration(color: Ink.cool, borderRadius: BorderRadius.circular(3)),
            ),
        ],
      ),
    );
  }
}

/// "Nhắc lúc nào?" for a reminder said without a time.
class AskTimeOverlay extends StatelessWidget {
  const AskTimeOverlay({super.key, required this.ask, required this.onAnswer});
  final AskTime ask;
  final void Function(Duration?) onAnswer;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xE6030609),
        child: Stack(
          children: [
            Positioned(
              left: 48,
              top: 60,
              width: 780,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NHẮC LÚC NÀO?', style: eyebrow(color: Ink.cool)),
                  const SizedBox(height: 10),
                  Text(ask.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(46, weight: FontWeight.w600, height: 1.1)),
                  const SizedBox(height: 10),
                  Text('Hoặc nói lại kèm giờ: “nhắc anh … lúc 3 giờ chiều”', style: metaStyle()),
                ],
              ),
            ),
            Positioned(
              right: 44,
              top: 66,
              child: Row(
                children: [
                  Pill('15 phút', key: const Key('ask-15'), style: PillStyle.cool, onTap: () => onAnswer(const Duration(minutes: 15))),
                  const SizedBox(width: 14),
                  Pill('1 giờ', key: const Key('ask-60'), style: PillStyle.cool, onTap: () => onAnswer(const Duration(hours: 1))),
                  const SizedBox(width: 14),
                  Pill('Bỏ', key: const Key('ask-cancel'), onTap: () => onAnswer(null)),
                ],
              ),
            ),
          ],
        ),
      );
}
