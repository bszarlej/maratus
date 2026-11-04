import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'chat_controller.dart';
import 'chat_game.dart';
import 'chat_protocol.dart';
import 'diagnostics_overlay.dart';
import 'network_lab.dart';

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
  NetworkLab? _lab;
  var _showDiagnostics = false;

  @override
  void dispose() {
    _lab?.dispose();
    if (widget.controller == null) _controller.dispose();
    _port.dispose();
    _url.dispose();
    _message.dispose();
    super.dispose();
  }

  bool get _canStart => _controller.canStart && _lab == null;

  void _send() {
    if (_controller.send(_message.text)) _message.clear();
  }

  /// Starts a simulated host and second client, and joins them.
  Future<void> _simulate() async {
    if (!_canStart) return;
    final lab = NetworkLab(clock: _controller.clock);
    setState(() => _lab = lab);
    await lab.start();
    if (mounted && identical(_lab, lab)) _rejoin();
  }

  void _rejoin() {
    final lab = _lab;
    if (lab == null) return;
    _controller.joinPeer(
      lab.connect(),
      description: 'Joining the simulated host',
    );
  }

  void _setSmoothing(bool value) {
    _controller.smoothing = value;
    _lab?.peer.smoothing = value;
  }

  void _disconnect() {
    _controller.disconnect();
    final lab = _lab;
    if (lab == null) return;
    setState(() => _lab = null);
    // Let the lab's game widgets leave the tree before closing their games.
    WidgetsBinding.instance.addPostFrameCallback((_) => lab.dispose());
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
                            enabled: _canStart,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _canStart
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
                          enabled: _canStart,
                          decoration: const InputDecoration(
                            labelText: 'Host URL',
                          ),
                          onSubmitted: _controller.join,
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _canStart
                            ? () => _controller.join(_url.text)
                            : null,
                        child: const Text('Join'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _canStart
                            ? () => unawaited(_simulate())
                            : null,
                        child: const Text('Simulate'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _Toggle(
                        key: const Key('smoothingToggle'),
                        label: 'Smoothing',
                        value: _controller.smoothing,
                        onChanged: _setSmoothing,
                      ),
                      _Toggle(
                        key: const Key('diagnosticsToggle'),
                        label: 'Diagnostics',
                        value: _showDiagnostics,
                        onChanged: (value) =>
                            setState(() => _showDiagnostics = value),
                      ),
                      TextButton(
                        onPressed: _canStart ? null : _disconnect,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ),
                  const Divider(),
                  _GamePanel(
                    key: const Key('chatGame'),
                    game: _controller.game,
                    height: 160,
                    title: 'This participant',
                    showDiagnostics: _showDiagnostics,
                  ),
                  if (_lab case final lab?) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final scenario in NetworkScenario.values)
                          OutlinedButton(
                            onPressed: () => lab.run(scenario, rejoin: _rejoin),
                            child: Text(scenario.label),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _GamePanel(
                            key: const Key('labHostGame'),
                            game: lab.host.game,
                            height: 120,
                            title: 'Simulated host',
                            showDiagnostics: _showDiagnostics,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _GamePanel(
                            key: const Key('labPeerGame'),
                            game: lab.peer.game,
                            height: 120,
                            title: 'Simulated client',
                            showDiagnostics: _showDiagnostics,
                          ),
                        ),
                      ],
                    ),
                  ],
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

/// A game canvas with its diagnostics shown over it when requested.
class _GamePanel extends StatelessWidget {
  const _GamePanel({
    required super.key,
    required this.game,
    required this.height,
    required this.title,
    required this.showDiagnostics,
  });

  final ChatGame game;
  final double height;
  final String title;
  final bool showDiagnostics;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GameWidget(game: game, autofocus: false),
          if (showDiagnostics) DiagnosticsOverlay(game: game, title: title),
        ],
      ),
    ),
  );
}

/// A compact chip that toggles one of the example's options.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => FilterChip(
    label: Text(label),
    selected: value,
    onSelected: onChanged,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}
