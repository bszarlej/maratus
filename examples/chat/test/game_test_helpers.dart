import 'package:flame/components.dart';
import 'package:maratus_chat/chat_game.dart';

/// Loads a game without a widget so tests can advance exact update boundaries.
Future<void> prepareChatGame(ChatGame game) async {
  if (!game.isLoaded) {
    game.onGameResize(Vector2(600, 160));
    // Tests explicitly perform the lifecycle normally driven by GameWidget.
    // ignore: invalid_use_of_internal_member
    await game.load();
    // ignore: invalid_use_of_internal_member
    game.mount();
  }
  await game.ready();
}
