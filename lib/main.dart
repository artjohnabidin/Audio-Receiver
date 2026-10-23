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

// Provide via: flutter run -d chrome --dart-define-from-file=env.json
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_KEY');
const speechTokenUrl = String.fromEnvironment('SPEECH_TOKEN_URL');
const iceServersJson = String.fromEnvironment(
  'WEBRTC_ICE_SERVERS',
  defaultValue: '[{"urls":"stun:stun.l.google.com:19302"}]',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
    );
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Receiver',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const ReceiverPage(),
    );
  }
}

class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  final _roomController = TextEditingController(text: 'event-1');
  final _speechHttpClient = http.Client();
  AudioReceiver? _receiver;
  SpeechTranscriber? _transcriber;
  VoidCallback? _audioAvailabilityListener;
  bool _showTranscript = false;

  bool get _configured =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      speechTokenUrl.isNotEmpty;

  Future<void> _start() async {
    debugPrint('[1] Connect button handler called');

    final room = _roomController.text.trim();
    if (room.isEmpty) return;
    setState(() => _showTranscript = true);
    try {
      final iceServers = (jsonDecode(iceServersJson) as List)
          .map((server) => Map<String, dynamic>.from(server as Map))
          .toList();
      final receiver = AudioReceiver(
        SupabaseSignaling(client: Supabase.instance.client, roomId: room),
        iceServers: iceServers,
      );
      setState(() => _receiver = receiver);
      void onAudioAvailabilityChanged() {
        debugPrint(
          '[2] Audio availability changed: '
          '${receiver.audioAvailable.value}',
        );

        if (receiver.audioAvailable.value) {
          debugPrint('[3] Calling _startTranscription');
          unawaited(_startTranscription(receiver));
        } else {
          unawaited(_stopTranscription());
        }
      }

      _audioAvailabilityListener = onAudioAvailabilityChanged;
      receiver.audioAvailable.addListener(onAudioAvailabilityChanged);

      debugPrint('[4] Calling receiver.start()');
      await receiver.start();
      debugPrint('[5] receiver.start() completed');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to join: $e')));
      await _stop();
    }
  }

  Future<void> _stop() async {
    final receiver = _receiver;
    final listener = _audioAvailabilityListener;
    if (receiver != null && listener != null) {
      receiver.audioAvailable.removeListener(listener);
    }
    _audioAvailabilityListener = null;
    await _stopTranscription();
    setState(() => _receiver = null);
    await receiver?.stop();
  }

  Future<void> _startTranscription(AudioReceiver receiver) async {
    debugPrint('[6] _startTranscription entered');

    if (_transcriber case final current? when !current.isStopped)
    {
      debugPrint('[6a] Transcriber already running');
      return;
    }
    final stream = receiver.remoteWebStream;

    debugPrint('[7] Remote stream is null: ${stream == null}');
    debugPrint('[8] Widget mounted: $mounted');

    if (stream == null || !mounted) return;
    final transcriber = _transcriber ?? SpeechTranscriber();
    setState(() => _transcriber = transcriber);
    try {
      debugPrint('[9] Checking Supabase session');

      final auth = Supabase.instance.client.auth;
      if (auth.currentSession == null) 
      {
        debugPrint('[10] Signing in anonymously');
        await auth.signInAnonymously();
      }

      debugPrint('[11] Fetching speech token');

      Future<SpeechToken> fetchSpeechToken() {
        final accessToken = auth.currentSession?.accessToken;
        debugPrint('accessToken: $accessToken');
        if (accessToken == null) {
          throw StateError('A Supabase session is required for speech access');
        }
        return SpeechTranscriberAuthService(
          backendBaseUrl: speechTokenUrl,
          httpClient: _speechHttpClient,
        ).fetchToken(accessToken);
      }

      final token = await fetchSpeechToken();
      debugPrint('[12] Speech token fetched successfully');

      debugPrint('[13] About to call transcriber.start');

      await transcriber.start(
        stream,
        token: token,
        refreshToken: fetchSpeechToken,
      );

      debugPrint('[14] transcriber.start completed');
    } catch (error) {
      if (transcriber.isStopped || !mounted) return;
      debugPrint('Transcription failed: $error');
    }
  }

  Future<void> _stopTranscription() async {
    final transcriber = _transcriber;
    if (transcriber == null || transcriber.isStopped) return;
    try {
      await transcriber.stop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stop transcription: $error')),
        );
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _enableAudio(AudioReceiver receiver) async {
    try {
      await receiver.enableAudioPlayback();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not enable audio: $error')));
    }
  }

  @override
  void dispose() {
    final receiver = _receiver;
    final listener = _audioAvailabilityListener;
    if (receiver != null && listener != null) {
      receiver.audioAvailable.removeListener(listener);
    }
    final transcriber = _transcriber;
    if (transcriber != null) {
      unawaited(
        transcriber.stop().catchError((Object error) {
          debugPrint('Could not stop transcription: $error');
        }),
      );
      transcriber.dispose();
    }
    _receiver?.stop();
    _speechHttpClient.close();
    _roomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final receiver = _receiver;
    final transcriber = _transcriber;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('WebRTC Audio Receiver'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            if (!_configured)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Missing Supabase or speech token service config.\nRun with --dart-define-from-file=env.json',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * 0.45,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: .stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: _roomController,
                        enabled: receiver == null,
                        decoration: const InputDecoration(
                          labelText: 'Room ID',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: receiver == null ? _start : _stop,
                        icon: Icon(
                          receiver == null ? Icons.headphones : Icons.stop,
                        ),
                        label: Text(receiver == null ? 'Connect' : 'Leave'),
                      ),
                      const SizedBox(height: 16),
                      if (receiver == null)
                        const _ConnectionStatus()
                      else
                        ValueListenableBuilder(
                          valueListenable: receiver.state,
                          builder: (_, state, _) =>
                              _ConnectionStatus(state: state),
                        ),
                      const SizedBox(height: 16),
                      if (receiver != null) ...[
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
                          builder: (_, available, _) => available
                              ? Align(
                                  alignment: Alignment.centerLeft,
                                  child: FilledButton.icon(
                                    onPressed: () => _enableAudio(receiver),
                                    icon: const Icon(Icons.volume_up),
                                    label: const Text('Enable audio'),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        // Hidden renderer; required for the browser to play remote audio.
                        SizedBox(
                          width: 1,
                          height: 1,
                          child: RTCVideoView(receiver.renderer),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (_showTranscript)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (transcriber case final current?)
                        ValueListenableBuilder(
                          valueListenable: current.status,
                          builder: (_, value, _) => Text(
                            value,
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
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Transcript',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 8),
                                Expanded(
                                  child: transcriber != null
                                      ? ValueListenableBuilder(
                                          valueListenable:
                                              transcriber.transcript,
                                          builder: (_, text, _) =>
                                              SingleChildScrollView(
                                                reverse: true,
                                                child: SelectableText(
                                                  text.isEmpty
                                                      ? 'Transcript will appear here'
                                                      : text,
                                                ),
                                              ),
                                        )
                                      : const SingleChildScrollView(
                                          child: SelectableText(
                                            'Transcript will appear here',
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
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
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({this.state});

  final ReceiverState? state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (title, description, icon, color) = switch (state) {
      null => (
        'Ready to connect',
        'Choose a room to start listening.',
        Icons.headphones,
        scheme.primary,
      ),
      ReceiverState.connecting => (
        'Connecting',
        'Establishing a signaling connection.',
        Icons.sync,
        scheme.primary,
      ),
      ReceiverState.waitingForBroadcaster => (
        'Waiting for broadcaster',
        'Connected to the room. Waiting for live audio.',
        Icons.hourglass_top,
        scheme.tertiary,
      ),
      ReceiverState.connected => (
        'Audio connected',
        'The live audio stream is ready.',
        Icons.graphic_eq,
        Colors.green.shade700,
      ),
      ReceiverState.disconnected => (
        'Disconnected',
        'The connection ended. Reconnect to continue listening.',
        Icons.link_off,
        scheme.error,
      ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(description, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.circle, size: 10, color: color),
        ],
      ),
    );
  }
}
