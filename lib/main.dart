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

  bool get _configured => acsTokenUrl.isNotEmpty;

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
                            final colors = Theme.of(context).colorScheme;

                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              color: selected
                                  ? colors.primaryContainer
                                  : colors.surfaceContainerLow,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: BorderSide(
                                  color: selected
                                      ? colors.primary
                                      : colors.outlineVariant,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
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
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: selected
                                              ? colors.primary
                                              : colors.secondaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Icon(
                                          selected
                                              ? Icons.graphic_eq
                                              : Icons.event,
                                          color: selected
                                              ? colors.onPrimary
                                              : colors.onSecondaryContainer,
                                          size: 21,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              event.title,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                            const SizedBox(height: 8),
                                            Wrap(
                                              spacing: 12,
                                              runSpacing: 4,
                                              children: [
                                                _EventMeta(
                                                  icon: Icons.calendar_today,
                                                  text: event.date,
                                                ),
                                                _EventMeta(
                                                  icon: Icons.schedule,
                                                  text: event.timeRange,
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Icon(
                                                  Icons.people_outline,
                                                  size: 15,
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                                const SizedBox(width: 6),
                                                Expanded(
                                                  child: Text(
                                                    event.speakers.join(', '),
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color: colors
                                                              .onSurfaceVariant,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              'ID ${event.id.toUpperCase()}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall
                                                  ?.copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Icon(
                                          selected && receiver != null
                                              ? Icons.check_circle
                                              : Icons.chevron_right,
                                          color: selected
                                              ? colors.primary
                                              : colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
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

class _EventMeta extends StatelessWidget {
  const _EventMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: colors.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}
