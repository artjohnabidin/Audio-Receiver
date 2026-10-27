# Audio Receiver

Flutter web ACS audio listener for the Swift broadcaster in `../Audio-Streaming`.
The event page uses the official Azure Communication Services Calling SDK,
not the legacy WebRTC/Supabase signaling transport.

## Run

Install Node.js 22+ and Flutter, then:

```sh
npm ci
npm run build
flutter run -d chrome --dart-define-from-file=env.json
```

Set the full `ACS_TOKEN_URL` endpoint in your ignored local `env.json`:

```json
{
	"ACS_TOKEN_URL": "https://your-authenticated-token-api.example/api/acsToken"
}
```

Sign in with Microsoft in both apps and select the same event. The listener
joins immediately, with outgoing microphone audio muted and no outgoing video.
The browser supplies a disabled silent `LocalAudioStream` instead of a microphone
stream: the ACS SDK otherwise waits for microphone permission while creating its
offer, even when joining muted. `videoOptions` is omitted completely because an
empty video-stream array still enables video initialization in this SDK.
Only incoming audio can be unmuted by listener controls. Either app may join
first; broadcaster Stop/Start removes/re-adds its participant in the same group.
Broadcaster Pause/Resume mutes/unmutes its microphone within ACS. Listener Mute
and Leave affect only that listener, never the broadcaster or other listeners.
**Enable audio** calls the SDK's incoming-audio unmute API; playback remains
subject to the browser's autoplay policy. Use HTTPS outside localhost.

Rebuild with `npm run build` after changing the browser adapter. Its generated
bundle is ignored by Git and must be built before Flutter run/build.

## Broadcaster Compatibility

The listener matches `ACSAudioStreamService` and `ACSCallConfig` in the Swift app:

- UUID event IDs are used directly as the ACS group locator (case-insensitive).
- Non-UUID/empty IDs use `7d9f1c20-5a34-4b67-8c12-3e6f90a2b451`.
- Both apps use the same four fixed UUIDs for the sample events, giving each
	event a separate ACS group. Keep the IDs identical in both apps.
- Both clients' ACS tokens must come from the **same ACS resource**.
- The group locator is not the ACS SDK's generated call-instance ID.
- No legacy `webrtc-signal`, remote-start commands, STUN or TURN settings are
	used by the active listener. Legacy transport files/tests remain inactive,
	matching the broadcaster's retained legacy implementation.

Connected/waiting status is based on ACS call and participant state. ACS group
participants do not carry application roles, so another listener can also
appear as a connected participant. These indicators are not backend event-live
status or proof of audible microphone audio.

## Token Endpoint

The receiver follows Swift's `ACSTokenService` request contract:

- `GET` to the full `ACS_TOKEN_URL`, with a 30-second timeout.
- `Accept: application/json`.
- `Authorization: Bearer <Microsoft ID token>` from Microsoft sign-in, not a
	Supabase token or Microsoft Graph access token.
- `x-functions-key: <function key>` when `ACS_TOKEN_FUNCTION_KEY` is configured.

The JSON response must contain `userId`, `token`,
and ISO-8601 `expiresOn`; issue a token with the `voip` scope. The browser uses
MSAL silent acquisition and ACS proactive token refresh during long calls.
Authentication failures require signing in again.

For controlled local testing against the same function used by Swift, set
`ACS_TOKEN_URL` to that function's URL and optionally set `ACS_TOKEN_FUNCTION_KEY`
in the ignored local defines file. The event page picks up that key through
`ACSTokenService` automatically; it is not copied from the native app. A key
compiled into Flutter web is **public**, even from an ignored file, so use a
disposable development key only and never publish that build.

Allow the listener origin in CORS, including preflight for `Authorization` and,
for direct function requests, `x-functions-key`. The endpoint must accept the web app's Microsoft token audience and
validate its tenant, issuer, audience, expiry, and user/event authorization.
For production, leave `ACS_TOKEN_FUNCTION_KEY` unset and use a server-side
authenticated proxy that supplies the function key, or a JWT-validated endpoint
that does not require a browser-held key. The deployment workflow intentionally
does not embed a function key. Never put ACS connection strings or resource keys
in browser configuration. This client does not change backend authentication.

## Optional Transcription

Set `SUPABASE_URL`, `SUPABASE_KEY` (public anon/publishable only), and
`SPEECH_TOKEN_URL` to retain the existing Azure Speech transcription flow.
The receiver passes ACS's incoming mixed `MediaStream` to Azure Speech; audio
is sent to that service. Supabase authenticates the existing speech token API,
not the ACS call. Without these settings, audio listening still works.
Playback mute does not stop transcription. Leaving the call stops transcription.

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
| Variable | `ACS_TOKEN_URL` | Full authenticated ACS token endpoint URL. |
| Variable | `STREAM_CONTROL_NEGOTIATE_URL` | Web PubSub negotiate endpoint for remote Start/Pause/Resume/Stop. |
| Variable (optional) | `SUPABASE_URL` | Supabase project URL for transcription auth. |
| Secret (optional) | `SUPABASE_KEY` | Supabase public anon or publishable key, never a service-role key. |
| Variable (optional) | `SPEECH_TOKEN_URL` | Base URL of the existing speech token API. |

The workflow installs pinned npm dependencies, tests and bundles ACS, then
builds Flutter. It does not use your ignored local `env.json`. All compile-time
values are visible in the published JavaScript even when supplied as secrets.

This workflow publishes static web files only; it does not provision Azure or
deploy token services. Configure the token API and Microsoft redirect URI for
the deployed HTTPS origin before testing with the Swift app.

## Verification

```sh
npm ci
npm test
npm run build
flutter analyze
flutter test test/acs_token_test.dart
flutter test --platform chrome
flutter build web --dart-define-from-file=env.json
```

ACS adapter tests use fake SDK objects to verify group resolution against Swift,
muted audio-only joining, token refresh, local playback, broadcaster departure
and return, disconnection, and cleanup. Token tests check the HTTP/auth contract
and invalid credentials. Existing browser WebRTC tests cover legacy code only.

A live iOS-to-browser test is required to verify Azure authorization/CORS,
microphone audio, browser playback restrictions, and transcription. Test either
join order, Pause/Resume, Stop/Start, multiple listeners, and leaving one listener
without interrupting the broadcaster. Mocks cannot establish live connectivity.
