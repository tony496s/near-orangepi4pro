import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/agents/agent_console.dart';
import 'package:near_app/agents/console_app.dart';
import 'package:near_app/agents/console_model.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/voice/voice_client.dart';

import '../support/fakes.dart';
import '../support/fonts.dart';

/// Screenshots of every scene go to this directory when set (NEAR_SHOTS=/some/dir flutter test ...).
final shots = Platform.environment['NEAR_SHOTS'];

class ConsoleHarness {
  ConsoleHarness(this.tester);
  final WidgetTester tester;
  final clock = FakeClock(DateTime(2026, 11, 18, 9));
  final voice = FakeVoice()..isReady = true;
  late final AgentConsole c = AgentConsole(voice: voice, clock: clock);
  static const shotKey = Key('shot');

  Future<void> pump() async {
    tester.view.physicalSize = const Size(1480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c.start(ticker: false);
    await tester.pumpWidget(RepaintBoundary(key: shotKey, child: ConsoleApp(console: c)));
    await settle();
  }

  Future<void> settle() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> run(Duration d) async {
    for (var t = 0; t < d.inMilliseconds; t += 200) {
      clock.advance(const Duration(milliseconds: 200));
      c.tick();
    }
    await settle();
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await run(const Duration(milliseconds: 200));
    }
    expect(done(), isTrue);
    await settle();
  }

  Future<void> tap(Key key) async {
    await tester.tap(find.byKey(key));
    await settle();
  }

  Future<void> shot(String name) async {
    final dir = shots;
    if (dir == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('the whole story by touch, every scene fits the strip', (tester) async {
    final h = ConsoleHarness(tester);
    await h.pump();
    await h.run(const Duration(seconds: 10));
    expect(find.text('harness-backend'), findsOneWidget);
    expect(find.text('Giao việc'), findsOneWidget);
    expect(find.text('NEAR · HỘP AGENT'), findsOneWidget);
    await h.shot('1-idle');

    await h.tap(const Key('slot'));
    expect(h.voice.sent.last, 'listen a1');
    h.voice.emit(const VoiceLevel(-22));
    await h.settle();
    expect(find.text('Nói việc cần giao…'), findsOneWidget);
    await h.shot('2-listening');
    h.voice.emit(const VoiceProcessing('a1'));
    await h.settle();
    expect(find.text('Đang hiểu ý anh…'), findsOneWidget);
    await h.shot('2b-processing');
    h.voice.emit(const VoiceFinal('a1', 'THÊM LOADING CHO NÚT ĐĂNG NHẬP'));
    await h.settle();
    expect(find.text('Thêm loading cho nút đăng nhập'), findsOneWidget);
    await h.run(const Duration(seconds: 2));
    await h.shot('3-new-lane');

    final task = h.c.lanes.last;
    await h.until(() => task.card is QuestionCard);
    await h.run(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('option-0')), findsOneWidget);
    await h.shot('4-question');
    await h.tap(const Key('option-0'));
    expect(task.card, isNull);

    final backend = h.c.lanes.first;
    await h.until(() => backend.card is DangerCard);
    await h.run(const Duration(milliseconds: 600));
    expect(find.textContaining('git push --force origin main'), findsOneWidget);
    await h.shot('5-danger');
    await h.tap(const Key('deny'));
    expect(backend.card, isNull);

    await h.until(() => task.card is ReviewCard);
    await h.run(const Duration(milliseconds: 600));
    expect(find.text('Duyệt & tạo PR'), findsOneWidget);
    await h.shot('6-review');
    await h.tap(const Key('approve'));

    await h.until(() => task.state == LaneState.ready);
    expect(find.byKey(const Key('ship')), findsOneWidget);
    await h.shot('7-ready');
    await h.tap(const Key('ship'));
    await h.run(const Duration(seconds: 4));
    expect(find.text('ĐANG SHIP BẢN TEST · TESTFLIGHT'), findsOneWidget);
    await h.shot('8-shipping');
    await h.until(() => task.card is ShipCard && (task.card! as ShipCard).done);
    await h.shot('8b-shipped');
    await h.until(() => h.c.why);
    expect(find.text('VÌ SAO LÀ NEAR'), findsOneWidget);
    await h.shot('9-why');
    await h.tap(const Key('why'));
    expect(h.c.why, isFalse);
    await h.shot('10-end');
  });

  testWidgets('five lanes and a review card still fit', (tester) async {
    final h = ConsoleHarness(tester);
    await h.pump();
    final task = h.c.addTask('Thêm loading cho nút đăng nhập ở màn hình chính của app điện thoại')!;
    h.c.addTask('Sửa api backend trả chậm khi tải danh sách');
    task
      ..card = const ReviewCard(tests: '42/42', diff: '+38 −6', files: 3, took: '4 phút')
      ..pending = ((_) => const [])
      ..state = LaneState.review;
    await h.run(const Duration(seconds: 3));
    expect(find.text('Duyệt & tạo PR'), findsOneWidget);
    await h.shot('11-five-lanes-review');
  });

  testWidgets('rail: tap shows the comparison, long press starts over', (tester) async {
    final h = ConsoleHarness(tester);
    await h.pump();
    h.c.addTask('Một việc');
    await h.settle();
    await h.tap(const Key('rail'));
    expect(h.c.why, isTrue);
    await h.tap(const Key('why'));
    await tester.longPress(find.byKey(const Key('rail')));
    await h.settle();
    expect(h.c.lanes, hasLength(3));
  });

  testWidgets('slot: long press gives the demo task without speaking; a note shows in the slot', (tester) async {
    final h = ConsoleHarness(tester);
    await h.pump();
    await tester.longPress(find.byKey(const Key('slot')));
    await h.settle();
    expect(h.c.lanes.last.task, 'Thêm loading cho nút đăng nhập');
    h.voice.isReady = false;
    await h.tap(const Key('slot'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Mic chưa sẵn sàng'), findsOneWidget);
    await h.shot('12-note');
  });

  testWidgets('rail: double tap toggles autoplay', (tester) async {
    final h = ConsoleHarness(tester);
    await h.pump();
    final rail = find.byKey(const Key('rail'));
    await tester.tap(rail);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(rail);
    await h.settle();
    expect(h.c.autoplay, isTrue);
    expect(h.c.why, isFalse);
    expect(find.text('NEAR · TỰ CHẠY'), findsOneWidget);
  });

  test('log lines: tool calls in mono, Vietnamese in the app font', () {
    expect(lineStyle(r'$ npm test   18/18 ✓', 13, const Color(0xFFFFFFFF)).fontFamily, mono);
    expect(lineStyle('Edit a.ts   +12 −3', 13, const Color(0xFFFFFFFF)).fontFamily, mono);
    expect(lineStyle('Anh chọn: Trong nút', 13, const Color(0xFFFFFFFF)).fontFamily, 'BeVietnamPro');
    expect(lineStyle('Đã dừng', 13, const Color(0xFFFFFFFF)).fontFamily, 'BeVietnamPro');
  });

  testWidgets('the VI/EN chip shows only when English is offered', (tester) async {
    final h = ConsoleHarness(tester);
    await h.pump();
    expect(find.byKey(const Key('lang')), findsNothing);
    h.voice.emit(const VoiceReady('m', langs: ['vi', 'en']));
    await h.settle();
    await h.tap(const Key('lang'));
    expect(h.c.lang, 'en');
    expect(find.text('EN'), findsOneWidget);
  });
}
