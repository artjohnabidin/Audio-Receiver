import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'acs_audio_receiver.dart';
import 'acs_token.dart';
import 'services/microsoft_auth_service.dart';
import 'speech_token.dart';
import 'speech_transcriber.dart';
import 'event_dto.dart';
import 'stream_control.dart';
import 'stream_control_browser_socket.dart';

// Use the same configuration values as main.dart.
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_KEY');
const speechTokenUrl = String.fromEnvironment('SPEECH_TOKEN_URL');
const acsTokenUrl = String.fromEnvironment('ACS_TOKEN_URL');
const streamControlNegotiateUrl = String.fromEnvironment(
  'STREAM_CONTROL_NEGOTIATE_URL',
);

class EventDetailPage extends StatefulWidget {
  final EventDTO event;
  final VoidCallback? onDisconnected;
  final ACSAudioReceiver Function()? createReceiver;
  final Future<SpeechToken> Function()? fetchSpeechToken;
  final StreamControlChannel Function()? createControlChannel;

  const EventDetailPage({
    super.key,
    required this.event,
    this.onDisconnected,
    this.createReceiver,
    this.fetchSpeechToken,
    this.createControlChannel,
  });

  @override
  State<EventDetailPage> createState() => _EventDetailPageState();
}

class _EventDetailPageState extends State<EventDetailPage> {
  final http.Client _httpClient = http.Client();

  ACSAudioReceiver? _receiver;
  StreamControlChannel? _control;
  bool _sendingControl = false;
  SpeechTranscriber? _transcriber;
  VoidCallback? _audioListener;
  Future<void> _audioQueue = Future<void>.value();
  int _audioRevision = 0;

  bool _connecting = true;
  bool _startingTranscription = false;
  bool _disposed = false;
  String? _error;

  bool get _configured =>
      widget.createReceiver != null || acsTokenUrl.isNotEmpty;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_connectToEvent());
      }
    });
  }

  Future<void> _connectToEvent() async {
    if (!_configured) {
      setState(() {
        _connecting = false;
        _error = 'Missing ACS token service configuration.';
      });
      return;
    }

    try {
      final tokenService = ACSTokenService(
        endpoint: acsTokenUrl,
        httpClient: _httpClient,
      );
      final receiver =
          widget.createReceiver?.call() ??
          ACSAudioReceiver(
            eventId: widget.event.id,
            fetchToken: () async => tokenService.fetchToken(
              await MicrosoftAuthService.acquireIdToken(),
            ),
          );

      _receiver = receiver;

      void onAudioChanged() {
        if (_disposed) return;
        final revision = ++_audioRevision;
        final stream = receiver.remoteWebStream;
        _audioQueue = _audioQueue
            .then((_) async {
              if (_disposed ||
                  _receiver != receiver ||
                  revision != _audioRevision)
                return;
              await _stopTranscription();
              if (stream != null) await _startTranscription(receiver);
            })
            .catchError((Object error) {
              if (mounted && !_disposed) {
                setState(() => _error = 'Transcription failed: $error');
              }
            });
      }

      _audioListener = onAudioChanged;
      receiver.audioAvailable.addListener(onAudioChanged);

      setState(() => _connecting = true);
      unawaited(_connectControl());

      await receiver.start();

      if (!mounted || _disposed) return;

      setState(() => _connecting = false);
    } catch (error) {
      debugPrint('Event connection failed: $error');

      if (mounted && !_disposed) {
        setState(() {
          _connecting = false;
          _error = 'Could not connect: $error';
        });
      }

      await _disconnect();
    }
  }

  Future<void> _connectControl() async {
    final control =
        widget.createControlChannel?.call() ??
        (streamControlNegotiateUrl.isEmpty
            ? null
            : StreamControlChannel(
                eventId: widget.event.id,
                negotiateUrl: streamControlNegotiateUrl,
                httpClient: _httpClient,
                fetchIdToken: MicrosoftAuthService.acquireIdToken,
                fetchUserId: MicrosoftAuthService.currentUserId,
                connectSocket: BrowserStreamControlSocket.connect,
              ));
    if (control == null || _disposed || !mounted) return;
    setState(() => _control = control);
    try {
      await control.connect();
    } catch (error) {
      debugPrint('Stream control connection failed: $error');
      if (!_disposed)
        control.error.value = 'Remote control unavailable: $error';
    }
  }

  Future<void> _sendControl(StreamControlAction action) async {
    final control = _control;
    if (control == null || _sendingControl) return;
    if (action == StreamControlAction.stop) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Stop the broadcast?'),
          content: const Text(
            'This ends the stream on the broadcaster device for all listeners.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Stop stream'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _sendingControl = true);
    try {
      await control.send(action);
    } catch (error) {
      if (mounted)
        setState(() => _error = 'Remote ${action.name} failed: $error');
    } finally {
      if (mounted) setState(() => _sendingControl = false);
    }
  }

  Future<void> _startTranscription(ACSAudioReceiver receiver) async {
    if (_disposed ||
        (widget.fetchSpeechToken == null &&
            (speechTokenUrl.isEmpty ||
                supabaseUrl.isEmpty ||
                supabaseAnonKey.isEmpty)) ||
        _startingTranscription ||
        (_transcriber != null && !_transcriber!.isStopped)) {
      return;
    }

    final stream = receiver.remoteWebStream;

    if (stream == null || !mounted) return;

    _startingTranscription = true;

    final transcriber = _transcriber ?? SpeechTranscriber();
    _transcriber = transcriber;

    setState(() {});

    try {
      Future<SpeechToken> fetchToken() async {
        final provider = widget.fetchSpeechToken;
        if (provider != null) return provider();
        final auth = Supabase.instance.client.auth;
        if (auth.currentSession == null) {
          await auth.signInAnonymously();
        }
        final accessToken = auth.currentSession?.accessToken;

        if (accessToken == null) {
          throw StateError('Supabase session is missing.');
        }

        return SpeechTranscriberAuthService(
          backendBaseUrl: speechTokenUrl,
          httpClient: _httpClient,
        ).fetchToken(accessToken);
      }

      final token = await fetchToken();

      if (_disposed ||
          !mounted ||
          _receiver != receiver ||
          !identical(stream, receiver.remoteWebStream)) {
        return;
      }

      await transcriber.start(stream, token: token, refreshToken: fetchToken);
    } catch (error) {
      debugPrint('Speech transcription failed: $error');

      if (mounted && !_disposed) {
        setState(() {
          _error = 'Transcription failed: $error';
        });
      }
    } finally {
      _startingTranscription = false;
    }
  }

  Future<void> _stopTranscription() async {
    final transcriber = _transcriber;

    if (transcriber == null || transcriber.isStopped) return;

    try {
      await transcriber.stop();
    } catch (error) {
      debugPrint('Could not stop transcription: $error');
    }
  }

  Future<void> _disconnect() async {
    final receiver = _receiver;
    final listener = _audioListener;

    _audioListener = null;
    _receiver = null;

    if (receiver != null && listener != null) {
      receiver.audioAvailable.removeListener(listener);
    }

    await _control?.close();
    await _stopTranscription();
    await receiver?.stop();

    if (mounted) {
      widget.onDisconnected?.call();
    }
  }

  @override
  void dispose() {
    _disposed = true;

    final receiver = _receiver;
    final listener = _audioListener;

    if (receiver != null && listener != null) {
      receiver.audioAvailable.removeListener(listener);
    }

    final transcriber = _transcriber;

    if (transcriber != null) {
      unawaited(
        transcriber.stop().catchError((Object error) {
          debugPrint('Transcriber cleanup failed: $error');
        }),
      );
      transcriber.dispose();
    }

    unawaited(receiver?.stop() ?? Future<void>.value());
    unawaited(_control?.close() ?? Future<void>.value());

    _httpClient.close();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final receiver = _receiver;
    final control = _control;
    final transcriber = _transcriber;

    return Scaffold(
      appBar: AppBar(
        title: Text(event.id.toUpperCase()),
        actions: [
          IconButton(
            tooltip: 'Leave event',
            icon: const Icon(Icons.close),
            onPressed: () async {
              await _disconnect();

              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(event.title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('${event.date} · ${event.timeRange}'),
            const SizedBox(height: 4),
            Text('Speakers: ${event.speakers.join(', ')}'),
            const Divider(height: 32),
            if (_connecting) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (receiver != null) ...[
              ValueListenableBuilder(
                valueListenable: receiver.state,
                builder: (context, state, _) {
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      state == ReceiverState.connected
                          ? Icons.graphic_eq
                          : Icons.sync,
                    ),
                    title: Text(switch (state) {
                      ReceiverState.connecting => 'Connecting',
                      ReceiverState.waitingForBroadcaster =>
                        'Waiting for broadcaster',
                      ReceiverState.connected => 'Audio connected',
                      ReceiverState.disconnected => 'Disconnected',
                    }),
                  );
                },
              ),
              ValueListenableBuilder(
                valueListenable: receiver.state,
                builder: (_, state, _) => state == ReceiverState.connected
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ValueListenableBuilder(
                          valueListenable: receiver.paused,
                          builder: (_, paused, _) => Wrap(
                            spacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  try {
                                    if (paused) {
                                      await receiver.resumeStreaming();
                                    } else {
                                      await receiver.pauseStreaming();
                                    }
                                  } catch (error) {
                                    if (mounted)
                                      setState(
                                        () =>
                                            _error = 'Playback failed: $error',
                                      );
                                  }
                                },
                                icon: Icon(
                                  paused ? Icons.volume_up : Icons.volume_off,
                                ),
                                label: Text(paused ? 'Unmute' : 'Mute'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  await _disconnect();
                                  if (context.mounted)
                                    Navigator.of(context).pop();
                                },
                                icon: const Icon(Icons.exit_to_app),
                                label: const Text('Leave stream'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              ValueListenableBuilder(
                valueListenable: receiver.error,
                builder: (context, error, _) => error == null
                    ? const SizedBox.shrink()
                    : Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
              ),
            ],
            if (control != null)
              _buildBroadcasterControls(control, receiver?.state),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 17,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.secondaryContainer,
                            child: Icon(
                              Icons.graphic_eq,
                              size: 18,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Live transcript',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                if (transcriber != null)
                                  ValueListenableBuilder(
                                    valueListenable: transcriber.status,
                                    builder: (context, status, _) => Text(
                                      status,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  )
                                else
                                  Text(
                                    'Waiting for broadcaster audio',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Expanded(
                      child: transcriber == null
                          ? const Center(
                              child: Text('Waiting for broadcaster audio'),
                            )
                          : ValueListenableBuilder(
                              valueListenable: transcriber.transcript,
                              builder: (context, entries, _) {
                                final messages = entries
                                    .where(
                                      (entry) =>
                                          entry.isFinal &&
                                          entry.text.isNotEmpty,
                                    )
                                    .toList();
                                if (messages.isEmpty) {
                                  return const Center(
                                    child: Text('Transcript will appear here'),
                                  );
                                }
                                return ListView.builder(
                                  reverse: true,
                                  padding: const EdgeInsets.all(16),
                                  itemCount: messages.length,
                                  itemBuilder: (context, index) {
                                    final message =
                                        messages[messages.length - index - 1];
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          CircleAvatar(
                                            radius: 13,
                                            backgroundColor: Theme.of(
                                              context,
                                            ).colorScheme.secondaryContainer,
                                            child: Icon(
                                              Icons.graphic_eq,
                                              size: 14,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSecondaryContainer,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 14,
                                                    vertical: 10,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .surfaceContainerLow,
                                                border: Border.all(
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.outlineVariant,
                                                ),
                                                borderRadius:
                                                    const BorderRadius.only(
                                                      topLeft: Radius.circular(
                                                        4,
                                                      ),
                                                      topRight: Radius.circular(
                                                        12,
                                                      ),
                                                      bottomRight:
                                                          Radius.circular(12),
                                                      bottomLeft:
                                                          Radius.circular(12),
                                                    ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    message.speakerLabel,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color: Theme.of(
                                                            context,
                                                          ).colorScheme.primary,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 3),
                                                  SelectableText(message.text),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBroadcasterControls(
    StreamControlChannel control,
    ValueListenable<ReceiverState>? audioState,
  ) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        control.connected,
        control.broadcasterState,
        control.error,
        ?audioState,
      ]),
      builder: (context, _) {
        final state = control.broadcasterState.value;
        final canStart =
            control.connected.value &&
            !_sendingControl &&
            (audioState?.value != ReceiverState.connected ||
                state == BroadcasterStreamState.stopped) &&
            (state == BroadcasterStreamState.unknown ||
                state == BroadcasterStreamState.stopped);
        final enabled =
            control.connected.value &&
            audioState?.value == ReceiverState.connected &&
            !_sendingControl &&
            state != BroadcasterStreamState.stopped;
        final paused = state == BroadcasterStreamState.paused;
        final controlError = control.error.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                control.connected.value
                    ? Icons.settings_remote
                    : Icons.portable_wifi_off,
              ),
              title: const Text('Broadcaster controls'),
              subtitle: Text(switch (state) {
                _ when !control.connected.value => 'Remote control connecting',
                BroadcasterStreamState.unknown => 'Remote control ready',
                BroadcasterStreamState.live => 'Broadcaster is live',
                BroadcasterStreamState.paused => 'Broadcaster is paused',
                BroadcasterStreamState.stopped =>
                  'Broadcaster stopped streaming',
              }),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: canStart
                      ? () => _sendControl(StreamControlAction.start)
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start stream'),
                ),
                FilledButton.icon(
                  onPressed: enabled
                      ? () => _sendControl(
                          paused
                              ? StreamControlAction.resume
                              : StreamControlAction.pause,
                        )
                      : null,
                  icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                  label: Text(paused ? 'Resume stream' : 'Pause stream'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: enabled
                      ? () => _sendControl(StreamControlAction.stop)
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop stream'),
                ),
              ],
            ),
            if (controlError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  controlError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        );
      },
    );
  }
}
