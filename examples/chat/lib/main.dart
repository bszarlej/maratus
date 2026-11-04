import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'chat_controller.dart';
import 'chat_protocol.dart';

/// Runs the WebSocket host/join example.
void main() => runApp(const ChatApp());

/// A small UI for running the same chat session on native and web platforms.
class ChatApp extends StatelessWidget {
  /// Creates the example app; tests may supply a controller.
  const ChatApp({super.key, this.controller});

  /// An optional externally owned controller, primarily for widget tests.
  final ChatController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Maratus · WebSocket chat',
    theme: ThemeData(colorSchemeSeed: const Color(0xffbe4b28)),
    home: _ChatPage(controller: controller),
  );
}

class _ChatPage extends StatefulWidget {
  const _ChatPage({this.controller});

  final ChatController? controller;

  @override
  State<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<_ChatPage> {
  late final _controller = widget.controller ?? ChatController();
  final _port = TextEditingController(text: '8080');
  final _url = TextEditingController(text: 'ws://localhost:8080/netcode');
  final _message = TextEditingController();
  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    _port.dispose();
    _url.dispose();
    _message.dispose();
    super.dispose();
  }

  void _send() {
    if (_controller.send(_message.text)) _message.clear();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Maratus · WebSocket chat')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Status: ${_controller.starting ? 'opening host' : _controller.state.name}'
                    ' · Peer: ${_controller.localPeer?.value ?? '—'}'
                    ' · Ready connections: ${_controller.readyPeers}',
                    key: const Key('sessionStatus'),
                  ),
                  const SizedBox(height: 12),
                  if (_controller.canHost)
                    Row(
                      children: [
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: _port,
                            enabled: _controller.canStart,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _controller.canStart
                              ? () => unawaited(_controller.host(_port.text))
                              : null,
                          child: const Text('Host'),
                        ),
                      ],
                    )
                  else
                    const Text(
                      'Run a native host, then join it from this browser.',
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _url,
                          enabled: _controller.canStart,
                          decoration: const InputDecoration(
                            labelText: 'Host URL',
                          ),
                          onSubmitted: _controller.join,
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _controller.canStart
                            ? () => _controller.join(_url.text)
                            : null,
                        child: const Text('Join'),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _controller.canStart
                          ? null
                          : _controller.disconnect,
                      child: const Text('Disconnect'),
                    ),
                  ),
                  const Divider(),
                  SizedBox(
                    height: 160,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: GameWidget(
                        key: const Key('chatGame'),
                        game: _controller.game,
                        autofocus: false,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _controller.activity.isEmpty
                        ? const Center(
                            child: Text('Host or join to exchange messages.'),
                          )
                        : ListView.builder(
                            reverse: true,
                            itemCount: _controller.activity.length,
                            itemBuilder: (context, index) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: SelectableText(
                                _controller.activity[_controller
                                        .activity
                                        .length -
                                    index -
                                    1],
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _message,
                    builder: (context, value, _) {
                      final length = value.text.trim().length;
                      final tooLong = length > ChatProtocol.messageLimit;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('messageInput'),
                              controller: _message,
                              enabled: _controller.canSend,
                              decoration: InputDecoration(
                                labelText: 'Message to everyone',
                                counterText:
                                    '$length / ${ChatProtocol.messageLimit}',
                                errorText: tooLong
                                    ? 'Message is too long.'
                                    : null,
                              ),
                              onSubmitted: (_) => _send(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: _controller.canSend && !tooLong
                                ? _send
                                : null,
                            child: const Text('Send'),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
