
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'audio_receiver.dart';
import 'signaling.dart';
import 'speech_token.dart';
import 'speech_transcriber.dart';
import 'event_dto.dart';

// Use the same configuration values as main.dart.
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_KEY');
const speechTokenUrl = String.fromEnvironment('SPEECH_TOKEN_URL');

const iceServersJson = String.fromEnvironment(
  'WEBRTC_ICE_SERVERS',
  defaultValue: '[{"urls":"stun:stun.l.google.com:19302"}]',
);

class EventDetailPage extends StatefulWidget {
  final EventDTO event;
  final VoidCallback? onDisconnected;

  const EventDetailPage({
    super.key,
    required this.event,
    this.onDisconnected,
  });

  @override
  State<EventDetailPage> createState() => _EventDetailPageState();
}

class _EventDetailPageState extends State<EventDetailPage> {
  final http.Client _httpClient = http.Client();

  AudioReceiver? _receiver;
  SpeechTranscriber? _transcriber;
  VoidCallback? _audioListener;

  bool _connecting = true;
  bool _startingTranscription = false;
  bool _disposed = false;
  String? _error;

  bool get _configured =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      speechTokenUrl.isNotEmpty;

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
        _error = 'Missing Supabase or Speech Token configuration.';
      });
      return;
    }

    try {
      // Reuse the Supabase client initialized by main.dart.
      final supabase = Supabase.instance.client;

      if (supabase.auth.currentSession == null) {
        await supabase.auth.signInAnonymously();
      }

      if (!mounted || _disposed) return;

      final iceServers = (jsonDecode(iceServersJson) as List)
          .map((server) => Map<String, dynamic>.from(server as Map))
          .toList();

      final receiver = AudioReceiver(
        SupabaseSignaling(
          client: supabase,
          roomId: widget.event.id,
        ),
        iceServers: iceServers,
      );

      _receiver = receiver;

      void onAudioChanged() {
        if (_disposed) return;

        if (receiver.audioAvailable.value) {
          unawaited(_startTranscription(receiver));
        } else {
          unawaited(_stopTranscription());
        }
      }

      _audioListener = onAudioChanged;
      receiver.audioAvailable.addListener(onAudioChanged);

      setState(() => _connecting = true);

      await receiver.start();

      if (!mounted || _disposed) return;

      setState(() => _connecting = false);

      // Handle audio that became available before start() completed.
      if (receiver.audioAvailable.value) {
        await _startTranscription(receiver);
      }
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

  Future<void> _startTranscription(AudioReceiver receiver) async {
    if (_disposed ||
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
      final auth = Supabase.instance.client.auth;

      if (auth.currentSession == null) {
        await auth.signInAnonymously();
      }

      Future<SpeechToken> fetchToken() async {
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

      if (_disposed || !mounted) return;

      await transcriber.start(
        stream,
        token: token,
        refreshToken: fetchToken,
      );
    } catch (error) {
      debugPrint('Speech transcription failed: $error');

      if (mounted && !_disposed && !transcriber.isStopped) {
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

    unawaited(
      receiver?.stop() ?? Future<void>.value(),
    );

    _httpClient.close();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final receiver = _receiver;
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

              if (mounted) {
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
            Text(
              event.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text('${event.date} · ${event.timeRange}'),
            const SizedBox(height: 4),
            Text('Speakers: ${event.speakers.join(', ')}'),
            const Divider(height: 32),
            if (_connecting)
              const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (receiver != null) ... [
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
                builder: (_, state, _) =>
                    state == ReceiverState.connected
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ValueListenableBuilder(
                          valueListenable: receiver.paused,
                          builder: (_, paused, _) => Wrap(
                            spacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: paused
                                    ? receiver.resumeStreaming
                                    : receiver.pauseStreaming,
                                icon: Icon(
                                  paused
                                      ? Icons.play_arrow
                                      : Icons.pause,
                                ),
                                label: Text(
                                  paused ? 'Resume' : 'Pause',
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: receiver.stopStreaming,
                                icon: const Icon(Icons.stop),
                                label: const Text('Stop'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              ValueListenableBuilder(
                valueListenable: receiver.pendingBroadcaster,
                builder: (_, pending, _) => pending != null
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            onPressed: receiver.startStreaming,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Start streaming'),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              ValueListenableBuilder(
                valueListenable: receiver.audioAvailable,
                builder: (context, available, _) {
                  if (!available) return const SizedBox.shrink();

                  return Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: () async {
                        try {
                          await receiver.enableAudioPlayback();
                        } catch (error) {
                          debugPrint('Audio playback failed: $error');
                        }
                      },
                      icon: const Icon(Icons.volume_up),
                      label: const Text('Enable audio'),
                    ),
                  );
                },
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Live Transcript',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (transcriber != null)
              ValueListenableBuilder(
                valueListenable: transcriber.status,
                builder: (context, status, _) => Text(
                  status,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              Text(
                'Waiting for broadcaster audio',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: transcriber == null
                      ? const Center(
                          child: Text('Transcript will appear here'),
                        )
                      : ValueListenableBuilder(
                          valueListenable: transcriber.transcript,
                          builder: (context, text, _) {
                            return SingleChildScrollView(
                              reverse: true,
                              child: SelectableText(
                                text.isEmpty
                                    ? 'Transcript will appear here'
                                    : text,
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
