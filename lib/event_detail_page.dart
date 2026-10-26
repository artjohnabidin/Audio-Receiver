
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'acs_audio_receiver.dart';
import 'acs_token.dart';
import 'services/microsoft_auth_service.dart';
import 'speech_token.dart';
import 'speech_transcriber.dart';
import 'event_dto.dart';

// Use the same configuration values as main.dart.
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_KEY');
const speechTokenUrl = String.fromEnvironment('SPEECH_TOKEN_URL');
const acsTokenUrl = String.fromEnvironment('ACS_TOKEN_URL');

class EventDetailPage extends StatefulWidget {
  final EventDTO event;
  final VoidCallback? onDisconnected;
  final ACSAudioReceiver Function()? createReceiver;
  final Future<SpeechToken> Function()? fetchSpeechToken;

  const EventDetailPage({
    super.key,
    required this.event,
    this.onDisconnected,
    this.createReceiver,
    this.fetchSpeechToken,
  });

  @override
  State<EventDetailPage> createState() => _EventDetailPageState();
}

class _EventDetailPageState extends State<EventDetailPage> {
  final http.Client _httpClient = http.Client();

  ACSAudioReceiver? _receiver;
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
      final receiver = widget.createReceiver?.call() ?? ACSAudioReceiver(
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
        _audioQueue = _audioQueue.then((_) async {
          if (_disposed || _receiver != receiver || revision != _audioRevision) return;
          await _stopTranscription();
          if (stream != null) await _startTranscription(receiver);
        }).catchError((Object error) {
          if (mounted && !_disposed) {
            setState(() => _error = 'Transcription failed: $error');
          }
        });
      }

      _audioListener = onAudioChanged;
      receiver.audioAvailable.addListener(onAudioChanged);

      setState(() => _connecting = true);

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

  Future<void> _startTranscription(ACSAudioReceiver receiver) async {
    if (_disposed ||
      (widget.fetchSpeechToken == null &&
        (speechTokenUrl.isEmpty || supabaseUrl.isEmpty || supabaseAnonKey.isEmpty)) ||
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

        if (_disposed || !mounted || _receiver != receiver ||
            !identical(stream, receiver.remoteWebStream)) {
          return;
        }

      await transcriber.start(
        stream,
        token: token,
        refreshToken: fetchToken,
      );
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
                                onPressed: () async {
                                  try {
                                    if (paused) {
                                      await receiver.resumeStreaming();
                                    } else {
                                      await receiver.pauseStreaming();
                                    }
                                  } catch (error) {
                                    if (mounted) setState(() => _error = 'Playback failed: $error');
                                  }
                                },
                                icon: Icon(
                                  paused
                                      ? Icons.volume_up
                                      : Icons.volume_off,
                                ),
                                label: Text(
                                  paused ? 'Unmute' : 'Mute',
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  await _disconnect();
                                  if (context.mounted) Navigator.of(context).pop();
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
                    : Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
