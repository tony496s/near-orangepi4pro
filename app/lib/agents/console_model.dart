/// Data of the agent console demo: lanes (one per agent, in the box or on another machine), the cards an agent shows
/// when it needs the human, and the script steps that drive each lane.
library;

/// Where an agent runs. The box is Near itself; the others are machines it drives through Harness, like the dial and
/// the phone do.
enum Machine {
  box('This machine', 'TRONG HỘP'),
  macbook('MacBook', 'TRÊN MACBOOK'),
  server('Server build', 'TRÊN SERVER');

  const Machine(this.name, this.tag);

  /// Name on the rail's machine list.
  final String name;

  /// Small upper-case label on a lane.
  final String tag;
}

enum Engine {
  claude('Claude'),
  codex('Codex');

  const Engine(this.label);
  final String label;
}

enum LaneState {
  running('Đang chạy'),
  asking('Đang hỏi anh'),
  blocked('Chờ duyệt lệnh'),
  review('Chờ duyệt kết quả'),
  ready('Sẵn sàng ship'),
  shipping('Đang ship'),

  /// Its machine (the MacBook) went to sleep: the agent stops where it was until it moves into the box or the
  /// machine wakes.
  paused('Tạm dừng · Mac đã ngủ'),
  done('Xong');

  const LaneState(this.label);
  final String label;

  /// The agent waits for a tap (or a voice answer) before it goes on.
  bool get needsHuman => this == asking || this == blocked || this == review;
}

/// What an agent shows when it needs the human. The lane widens to fit it.
sealed class AgentCard {
  const AgentCard();
}

/// The agent asks a question; each option is a wide button. [recommended] is starred.
final class QuestionCard extends AgentCard {
  const QuestionCard(this.question, this.options, {this.recommended = 0});
  final String question;
  final List<String> options;
  final int recommended;
}

/// A command the box does not let through on its own. Choice 0 denies, 1 allows.
final class DangerCard extends AgentCard {
  const DangerCard(this.command, this.why);
  final String command;
  final String why;

  static const deny = 0;
  static const allow = 1;
}

/// The agent is done: before/after, tests and diff. Choice 0 approves (push + PR), 1 asks for another pass.
final class ReviewCard extends AgentCard {
  const ReviewCard({required this.tests, required this.diff, required this.files, required this.took});
  final String tests;
  final String diff;
  final int files;
  final String took;

  static const approve = 0;
  static const redo = 1;
}

/// A build on its way to testers: [current] is the stage in progress, [stages].length when all are done. [places]
/// (same length as [stages], or empty) says where each stage runs, e.g. the iOS build on the build server because the
/// board (ARM Linux) cannot build iOS.
final class ShipCard extends AgentCard {
  const ShipCard(this.stages, this.current, {required this.version, this.places = const []});
  final List<String> stages;
  final int current;
  final String version;
  final List<String> places;

  bool get done => current >= stages.length;

  String placeOf(int stage) => stage >= 0 && stage < places.length ? places[stage] : '';
}

/// The machine an agent runs on went to sleep with the agent half way. Choice 0 moves the agent (branch and session)
/// into the box, where it carries on; 1 leaves it paused until the machine wakes.
final class HandoffCard extends AgentCard {
  const HandoffCard(this.from);
  final Machine from;

  static const move = 0;
  static const stay = 1;
}

/// One step of a lane's script, applied [after] the previous one.
sealed class Step {
  const Step(this.after);
  final Duration after;
}

const beat = Duration(milliseconds: 1600);

/// A line in the lane's log. [command]: a shell command the box let through on its own (counted on the rail).
final class Say extends Step {
  const Say(this.text, {Duration after = beat, this.command = false, this.progress}) : super(after);
  final String text;
  final bool command;
  final double? progress;
}

/// Shows [card] and waits for the human; [next] gives the steps that follow the chosen option.
final class Ask extends Step {
  const Ask(this.card, this.next, {Duration after = beat}) : super(after);
  final AgentCard card;
  final List<Step> Function(int choice) next;
}

/// Waits until [flag] is raised (by another lane). Meanwhile the lane logs [idle] lines, one every [every], so it
/// still looks busy.
final class Wait extends Step {
  const Wait(this.flag, {this.idle = const [], this.every = const Duration(seconds: 5)}) : super(Duration.zero);
  final String flag;
  final List<String> idle;
  final Duration every;
}

/// Moves the lane to [machine] (after a handoff).
final class MoveTo extends Step {
  const MoveTo(this.machine, {Duration after = Duration.zero}) : super(after);
  final Machine machine;
}

/// Raises [flag] for the lanes that wait on it.
final class Raise extends Step {
  const Raise(this.flag, {Duration after = Duration.zero}) : super(after);
  final String flag;
}

/// One stage of a ship (see [ShipCard]); index == stages.length marks the ship done.
final class ShipStage extends Step {
  const ShipStage(this.index, {Duration after = beat}) : super(after);
  final int index;
}

/// The agent is done. [shippable]: a "ship" button (or saying "ship") starts the ship steps.
final class Finish extends Step {
  const Finish(this.summary, {this.shippable = false, Duration after = beat}) : super(after);
  final String summary;
  final bool shippable;
}

class Lane {
  Lane({
    required this.id,
    required this.repo,
    required this.engine,
    required this.task,
    required this.startedAt,
    required List<Step> steps,
    this.machine = Machine.box,
    this.voiceGiven = false,
    this.progress = 0,
    List<String> log = const [],
  })  : steps = [...steps],
        log = [...log];

  final String id;
  final String repo;
  final Engine engine;
  final String task;

  /// Where the agent runs; changes when it moves into the box.
  Machine machine;

  /// The task was given by voice on the box (the lane shows a mic mark).
  final bool voiceGiven;
  final DateTime startedAt;
  final List<Step> steps;
  final List<String> log;

  double progress;
  LaneState state = LaneState.running;
  AgentCard? card;
  String? summary;
  bool shippable = false;
  DateTime? finishedAt;

  /// Index of the next step, and when it is due (null: not scheduled yet).
  int cursor = 0;
  DateTime? nextAt;

  /// Follow-ups of the card on screen.
  List<Step> Function(int)? pending;

  /// Since when the lane waits for the human (a card, or a ship button); null while it works.
  DateTime? waitingSince;

  /// Idle lines of a [Wait]: which comes next, and when.
  int idleIndex = 0;
  DateTime? idleAt;

  static const maxLog = 30;

  void addLog(String line) {
    log.add(line);
    if (log.length > maxLog) log.removeRange(0, log.length - maxLog);
  }

  Duration elapsed(DateTime now) => (finishedAt ?? now).difference(startedAt);
}
