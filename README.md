# audio_receiver

Flutter web listener for the Swift broadcaster in `../Audio-Streaming`.

## Run

Set `SUPABASE_URL` and `SUPABASE_KEY` in your local `env.json`, then run:

```sh
flutter run -d chrome --dart-define-from-file=env.json
```

Use the exact event ID selected in the Swift app as the Room ID. Either peer
may join first. Both apps must use the same Supabase project and the public
`webrtc:<eventID>` channel with Broadcast event `webrtc-signal`.

The listener discovers the broadcaster with a sessionless `join`, adopts its
session ID, sends `peer-ready`, and creates one receive-only audio offer. The
broadcaster answers with a send-only microphone track. Local ICE follows the
offer; remote ICE waits for the answer. Click **Enable audio** after the remote
track arrives to satisfy browser playback restrictions. The listener does not
request microphone access. This implementation supports one listener per stream.

## Local speech-to-text

When the remote audio track arrives, English streaming speech recognition
starts automatically in the browser with sherpa-onnx WebAssembly. Audio stays
in the browser and is not sent to a speech provider. The first use downloads an
approximately 44 MB English model from a pinned
[Apache-2.0 Hugging Face model revision](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/tree/d42f2d9f7ca24806fb667456a18a9f1b60f70d16);
this 2023 model uses sherpa's `zipformer` model type, not `zipformer2`. Model
inference uses the listener's CPU. No API key or per-minute STT charge is
required. The listener's browser must have enough memory and processing
capacity for the model, and a slow device may show more transcription delay.

Transcription reads the existing remote WebRTC audio and does not request
microphone permission. Click **Enable audio** for playback; this gesture also
resumes transcription if the browser suspends its audio processing. While
running, the status reports the resampled input's RMS and peak levels in dBFS
once per second; this measures levels only and does not record or send audio.
Audio frames with RMS below -60 dBFS are passed to the recognizer as silence;
the displayed meter shows the input level before this gate. Peaks close to
0 dBFS can indicate clipping. When the remote audio ends or the room is left,
the recognizer stops but the transcript stays visible.

## ICE Servers

The default Google STUN server is useful for local testing but cannot connect
all NAT/firewall combinations. Set `WEBRTC_ICE_SERVERS` to a JSON-encoded array
of ICE servers, including TURN, in your local defines file:

```json
{
	"WEBRTC_ICE_SERVERS": "[{\"urls\":[\"stun:stun.l.google.com:19302\"]},{\"urls\":[\"turns:turn.example.com:5349\"],\"username\":\"temporary-user\",\"credential\":\"temporary-password\"}]"
}
```

Configure working ICE servers on Swift as well. Use short-lived TURN credentials;
compile-time defines are visible in the web bundle, not secret storage. For
production, fetch credentials from your backend when creating the receiver.
Supabase carries signaling only, not the audio. Use HTTPS outside localhost.

## Production deployment

The GitHub Actions workflow in `.github/workflows/deploy-web.yml` builds a release
Flutter web bundle and uploads it to an existing Azure Static Web App on pushes
to `main`. You can also run it manually from the Actions tab.

Create an Azure Static Web App with deployment source **Other** to avoid creating
a second deployment workflow. In GitHub, open **Settings > Secrets and variables
> Actions** and configure:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `AZURE_STATIC_WEB_APPS_API_TOKEN` | Deployment token from the target Azure Static Web App. |
| Variable | `SUPABASE_URL` | Your Supabase project URL. |
| Secret | `SUPABASE_KEY` | Supabase public anon or publishable key, never a service-role or secret key. |
| Variable (optional) | `WEBRTC_ICE_SERVERS` | JSON array of ICE servers; defaults to Google STUN. |

The workflow does not use your ignored local `env.json`. Compile-time values,
including the Supabase public key and any TURN credentials, are visible in the
published JavaScript even when supplied through GitHub secrets. Use the runtime
TURN credential approach described above for production connectivity.

This workflow publishes static web files only; it does not provision Azure or
deploy Supabase services. After deployment, open the Azure HTTPS URL and verify
joining a room, remote audio playback, and transcription with the Swift app.

## Verification

```sh
flutter analyze
flutter test --platform chrome
flutter build web
```

The browser regression tests use real local WebRTC peers and fake signaling to
check discovery, receive-only SDP, ICE ordering, duplicate announcements,
signaling failure, and cleanup. A physical iOS-to-browser test is still needed
to verify microphone audio, Supabase authorization, and TURN across networks.
