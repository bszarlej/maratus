import 'package:flutter/material.dart';

import 'chat_game.dart';

/// Shows a game's network diagnostics over the top of its canvas.
class DiagnosticsOverlay extends StatelessWidget {
  /// Creates an overlay for [game]'s diagnostics, headed by [title].
  const DiagnosticsOverlay({
    super.key,
    required this.game,
    required this.title,
  });

  /// The game whose session is summarized.
  final ChatGame game;

  /// The participant the game belongs to.
  final String title;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topRight,
    child: IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xd90e171b),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ValueListenableBuilder<List<String>>(
          valueListenable: game.diagnostics,
          builder: (context, lines, _) => Text(
            [title, if (lines.isEmpty) 'No session' else ...lines].join('\n'),
            style: const TextStyle(
              color: Color(0xffc7d4d9),
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ),
      ),
    ),
  );
}
