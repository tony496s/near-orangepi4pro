import 'console_model.dart';

/// The scripted agents of the demo. Logs read like the tool calls of a coding agent; the repos and numbers are made up.
///
/// Story (flags between lanes in brackets):
/// 1. three agents already run in the box (backend, near-app, docs);
/// 2. a task given by voice opens a fourth lane ([loginScript]); it asks a question → [asked];
/// 3. the backend agent then wants `git push --force` and is stopped until the human decides → [danger-done];
/// 4. the voice task shows its before/after for approval → [approved], then can be shipped → [shipped].
abstract final class Flags {
  static const asked = 'asked';
  static const dangerDone = 'danger-done';
  static const approved = 'approved';
  static const shipped = 'shipped';
}

const shipStages = ['CI build', 'Ký app', 'Upload', 'Apple xử lý'];
const shipVersion = '0.1.71';

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

/// The three lanes running when the demo starts, started [now] minus their age.
List<Lane> initialLanes(DateTime now) => [
      Lane(
        id: 'backend',
        repo: 'harness-backend',
        engine: Engine.claude,
        task: 'Sửa API login trả lỗi 500 khi token hết hạn',
        startedAt: now.subtract(_s(6 * 60 + 12)),
        progress: .35,
        log: const ['Read src/auth/session.ts', r'$ npm test -- auth   15/18'],
        steps: backendScript(),
      ),
      Lane(
        id: 'near-app',
        repo: 'near-app',
        engine: Engine.codex,
        task: 'Viết test cho bộ hiểu giờ tiếng Việt',
        startedAt: now.subtract(_s(11 * 60 + 40)),
        progress: .45,
        log: const ['Read lib/domain/intent/vi_time.dart', r'$ flutter test test/domain   31/42'],
        steps: nearAppScript(),
      ),
      Lane(
        id: 'docs',
        repo: 'harness-docs',
        engine: Engine.claude,
        task: 'Viết lại hướng dẫn cài đặt trên Linux',
        startedAt: now.subtract(_s(2 * 60 + 5)),
        progress: .2,
        log: const ['Read docs/install.md', 'Read scripts/install.sh'],
        steps: docsScript(),
      ),
    ];

List<Step> backendScript() => [
      Say('Grep "refreshToken"   14 matches', after: _s(2)),
      Say('Edit src/auth/session.ts   +12 −3', after: _s(3), progress: .45),
      Say(r'$ npm test -- auth   18/18 ✓', command: true, after: _s(3), progress: .55),
      Say('Edit src/routes/login.ts   +6 −2', after: _s(3), progress: .6),
      const Wait(Flags.asked, idle: [
        r'$ npm run lint   0 issues',
        'Read src/auth/token.ts',
        r'$ npm test -- login   9/9 ✓',
        'Read docs/auth.md',
      ]),
      Say(r'$ git commit -m "fix: refresh expired token"', command: true, after: _s(2.5), progress: .8),
      Ask(
        const DangerCard('git push --force origin main',
            'Ghi đè nhánh main trên GitHub: 3 commit mới của người khác sẽ mất.'),
        (choice) => choice == DangerCard.deny
            ? [
                Say('Đã dừng, không push --force', after: _s(.6)),
                Say(r'$ git switch -c fix/login-500', command: true, after: _s(1.2)),
                const Raise(Flags.dangerDone),
                Say(r'$ git push -u origin fix/login-500', command: true, after: _s(1.5)),
                Say(r'$ gh pr create   PR #129', command: true, after: _s(1.5), progress: 1),
                Finish('PR #129 · chờ review', after: _s(1.2)),
              ]
            : [
                Say(r'$ git push --force origin main', after: _s(.6)),
                const Raise(Flags.dangerDone),
                Finish('Đã push --force lên main', after: _s(1.2)),
              ],
        after: _s(3.5),
      ),
    ];

List<Step> nearAppScript() => [
      Say('Edit test/domain/vi_time_test.dart   +40', after: _s(2.5), progress: .5),
      Say(r'$ flutter test test/domain   35/42', command: true, after: _s(3), progress: .6),
      Say('Read lib/domain/intent/vi_numbers.dart', after: _s(3)),
      Say('Edit vi_numbers.dart   +4 −1', after: _s(3), progress: .7),
      Say(r'$ flutter test test/domain   38/42', command: true, after: _s(3), progress: .75),
      const Wait(Flags.dangerDone, idle: [
        'Read test/support/fakes.dart',
        r'$ flutter test test/domain   38/42',
        'Edit test/domain/vi_time_test.dart   +12',
        r'$ dart analyze   0 issues',
      ], every: Duration(seconds: 6)),
      Say(r'$ flutter test test/domain   42/42 ✓', command: true, after: _s(4), progress: .95),
      Say(r'$ gh pr create   PR #127', command: true, after: _s(3), progress: 1),
      Finish('PR #127 · 42/42 ✓', after: _s(1.5)),
    ];

List<Step> docsScript() => [
      Say('Edit docs/install.md   +58 −31', after: _s(4), progress: .4),
      Say('Read scripts/setup.sh', after: _s(4)),
      Say(r'$ markdownlint docs   0 issues', command: true, after: _s(4), progress: .55),
      const Wait(Flags.approved, idle: [
        'Read docs/troubleshooting.md',
        'Edit docs/install.md   +12 −4',
        r'$ markdownlint docs   0 issues',
        'Read scripts/install.sh',
      ], every: Duration(seconds: 7)),
      Say(r'$ gh pr create   PR #130', command: true, after: _s(5), progress: 1),
      Finish('PR #130 · chờ review', after: _s(1.5)),
    ];

/// The task the presenter gives by voice ("thêm loading cho nút đăng nhập").
List<Step> loginScript() => [
      Say('Read lib/auth/login_screen.dart', after: _s(1.2), progress: .1),
      Say('Grep "LoginButton"   2 usages', after: _s(1.6), progress: .15),
      Say('Read lib/widgets/login_button.dart', after: _s(1.6), progress: .2),
      Ask(
        const QuestionCard('Spinner nằm trong nút, hay thay cả nút bằng spinner?', ['Trong nút', 'Thay cả nút']),
        (choice) => [const Raise(Flags.asked)],
        after: _s(1.8),
      ),
      Say('Edit login_button.dart   +24 −4', after: _s(1.8), progress: .4),
      Say('Edit login_screen.dart   +8 −2', after: _s(1.8), progress: .5),
      Say(r'$ flutter test   41/42', command: true, after: _s(2), progress: .6),
      Say('Edit test/login_button_test.dart   +6', after: _s(2), progress: .7),
      Say(r'$ flutter test   42/42 ✓', command: true, after: _s(2), progress: .85),
      Say('Chụp màn trước / sau', after: _s(1.5), progress: .9),
      const Wait(Flags.dangerDone, idle: [r'$ flutter analyze   0 issues', 'Read lib/auth/login_screen.dart']),
      _review(),
    ];

Ask _review() => Ask(
      const ReviewCard(tests: '42/42', diff: '+38 −6', files: 3, took: '4 phút'),
      (choice) => choice == ReviewCard.approve
          ? [
              Say(r'$ git push -u origin feat/login-loading', command: true, after: _s(.6)),
              Say(r'$ gh pr create   PR #128', command: true, after: _s(1.2), progress: 1),
              const Raise(Flags.approved),
              Say('CI: build ✓ · test ✓', after: _s(2.5)),
              Finish('PR #128 · CI ✓', shippable: true, after: _s(.8)),
            ]
          : [
              Say('Làm lại: spinner nhỏ hơn, giữ chữ trên nút', after: _s(.6)),
              Say('Edit login_button.dart   +3 −3', after: _s(1.8)),
              Say(r'$ flutter test   42/42 ✓', command: true, after: _s(2)),
              _review(),
            ],
      after: _s(1.5),
    );

/// Steps of a ship to TestFlight, appended to a shippable lane.
List<Step> shipScript() => [
      for (var i = 0; i <= shipStages.length; i++)
        ShipStage(i, after: i == 0 ? Duration.zero : _s(i == shipStages.length ? 4 : 2.8)),
      Finish('Bản $shipVersion đã lên TestFlight', after: _s(4)),
      const Raise(Flags.shipped),
    ];

/// Any other task given by voice: a short generic run.
List<Step> genericScript() => [
      Say('Read README.md', after: _s(1.2), progress: .1),
      Say('Grep   6 matches', after: _s(2), progress: .25),
      Say('Edit 2 file   +18 −5', after: _s(3), progress: .5),
      Say(r'$ npm test   ✓', command: true, after: _s(3), progress: .8),
      Say(r'$ gh pr create', command: true, after: _s(3), progress: 1),
      Finish('Xong · chờ review', after: _s(1.5)),
    ];
