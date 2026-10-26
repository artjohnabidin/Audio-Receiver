import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'acs_audio_receiver.dart';
import 'event_detail_page.dart';
import 'event_dto.dart';
import 'login_page.dart';
import 'services/microsoft_auth_service.dart';
import 'speech_transcriber.dart';

// Provide via: flutter run -d chrome --dart-define-from-file=env.json
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_KEY');
const speechTokenUrl = String.fromEnvironment('SPEECH_TOKEN_URL');
const acsTokenUrl = String.fromEnvironment('ACS_TOKEN_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
    );
  }
  var initiallySignedIn = false;
  try {
    initiallySignedIn = await MicrosoftAuthService.handleRedirect();
  } catch (error) {
    debugPrint('Microsoft redirect sign-in failed: $error');
  }
  runApp(MyApp(initiallySignedIn: initiallySignedIn));
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    this.signIn = MicrosoftAuthService.signIn,
    this.initiallySignedIn = false,
  });

  final Future<void> Function() signIn;
  final bool initiallySignedIn;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Receiver',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: initiallySignedIn
          ? const ReceiverPage()
          : LoginPage(
              onSignIn: signIn,
              destinationBuilder: (_) => const ReceiverPage(),
            ),
    );
  }
}

class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  // final _roomController = TextEditingController(text: 'event-1');
  EventDTO? _selectedEvent;
  final _speechHttpClient = http.Client();
  ACSAudioReceiver? _receiver;
  SpeechTranscriber? _transcriber;
  VoidCallback? _audioAvailabilityListener;

  bool get _configured =>
      acsTokenUrl.isNotEmpty;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final receiver = _receiver;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Event Monitoring'),
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
                      'Missing ACS token service config.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else
              Expanded(
                // constraints: BoxConstraints(
                //   maxHeight: constraints.maxHeight * 0.55,
                // ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: .stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Available Events',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          ...events.map((event) {
                            final selected = _selectedEvent?.id == event.id;

                            return Card(
                              color: selected
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : null,
                              child: ListTile(
                                leading: Icon(
                                  selected ? Icons.graphic_eq : Icons.event,
                                ),
                                title: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '${event.id.toUpperCase()} - ',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      TextSpan(text: event.title),
                                    ],
                                  ),
                                ),
                                subtitle: Text(
                                  '${event.date}\n'
                                  '${event.timeRange}\n'
                                  'Speakers: ${event.speakers.join(', ')}',
                                ),
                                isThreeLine: true,
                                trailing: selected && receiver != null
                                    ? const Icon(Icons.check_circle)
                                    : const Icon(Icons.chevron_right),
                                onTap: () {
                                  setState(() {
                                    _selectedEvent = event;
                                  });

                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => EventDetailPage(
                                        event: event,
                                        onDisconnected: () {
                                          if (!mounted) return;

                                          setState(() {
                                            _selectedEvent = null;
                                          });
                                        },
                                      ),
                                    ),
                                  );

                                  if (!mounted) return;
                                  setState(() {
                                    _selectedEvent = null;
                                  });
                                },
                              ),
                            );
                          }),
                        ],
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
