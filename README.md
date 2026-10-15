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
