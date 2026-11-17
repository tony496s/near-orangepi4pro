import 'console_model.dart';

/// Widths on the 1480 px strip: the status rail on the left, the "giao việc" slot on the right, lanes in between.
const railWidth = 214.0;
const slotIdleWidth = 138.0;
const slotActiveWidth = 360.0;

/// A lane never gets narrower than this, even next to a wide card.
const laneMinWidth = 125.0;

/// Width a lane asks for while it shows [card]; null: an equal share of what is left.
double? wantedWidth(AgentCard? card) => switch (card) {
      null => null,
      QuestionCard() => 560,
      DangerCard() => 640,
      ReviewCard() => 700,
      ShipCard() => 580,
      HandoffCard() => 560,
    };

/// Width of each lane in [total]: lanes with a card get what they ask for, the others share the rest equally. When
/// the rest would leave a lane under [laneMinWidth], the card lanes give way.
List<double> laneWidths(List<AgentCard?> cards, double total) {
  if (cards.isEmpty) return const [];
  final wants = [for (final c in cards) wantedWidth(c)];
  final plain = wants.where((w) => w == null).length;
  final wide = wants.whereType<double>().fold(0.0, (a, b) => a + b);
  if (plain == 0) return [for (final w in wants) w! * total / wide];
  var scale = 1.0;
  var rest = total - wide;
  if (rest < laneMinWidth * plain) {
    rest = laneMinWidth * plain;
    scale = wide == 0 ? 1 : ((total - rest) / wide).clamp(0.0, 1.0);
  }
  return [for (final w in wants) w == null ? rest / plain : w * scale];
}
