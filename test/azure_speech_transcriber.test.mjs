import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(
  new URL('../web/azure_speech_transcriber.js', import.meta.url),
  'utf8',
);

test('uses the Speech v2 endpoint for continuous language identification', async () => {
  let speechConfig;
  let transcriber;
  const endpointCalls = [];
  const properties = [];
  const sdk = {
    PropertyId: {
      SpeechServiceConnection_LanguageIdMode: 'languageIdMode',
      SpeechServiceResponse_DiarizeIntermediateResults: 'diarizeInterim',
    },
    ResultReason: { RecognizedSpeech: 'recognized' },
    SpeechConfig: {
      fromEndpoint(endpoint, ...auth) {
        endpointCalls.push({ url: endpoint.href, auth });
        speechConfig = {
          setProperty: (...args) => properties.push(args),
        };
        return speechConfig;
      },
    },
    AutoDetectSourceLanguageConfig: {
      fromLanguages: (languages) => ({ languages }),
    },
    AutoDetectSourceLanguageResult: {
      fromResult: () => ({ language: 'en-US' }),
    },
    AudioConfig: { fromStreamInput: () => ({ close() {} }) },
    ConversationTranscriber: {
      FromConfig: () => {
        transcriber = {
          startTranscribingAsync: (onStarted) => onStarted(),
          stopTranscribingAsync: (onStopped) => onStopped(),
          close() {},
        };
        return transcriber;
      },
    },
  };
  const context = { SpeechSDK: sdk, console, setTimeout, clearTimeout, URL };
  context.globalThis = context;
  vm.runInNewContext(source, context);

  const transcriptEvents = [];
  await context.azureSpeechTranscriber.start(
    {},
    'speech-token',
    'japaneast',
    (...event) => transcriptEvents.push(event),
    () => {},
  );

  assert.deepEqual(endpointCalls, [{
    url: 'wss://japaneast.stt.speech.microsoft.com/speech/universal/v2',
    auth: [],
  }]);
  assert.equal(speechConfig.authorizationToken, 'speech-token');
  assert.ok(properties.some(([key, value]) =>
    key === 'languageIdMode' && value === 'Continuous'));
  assert.ok(properties.some(([key, value]) =>
    key === 'diarizeInterim' && value === 'true'));
  assert.equal(typeof transcriber.transcribed, 'function');
  transcriber.transcribing(null, {
    result: { text: 'Hello there', speakerId: 'Guest-1' },
  });
  transcriber.transcribed(null, {
    result: {
      reason: 'recognized',
      text: 'Hello there.',
      speakerId: 'Guest-1',
    },
  });
  assert.deepEqual(transcriptEvents.map((event) => Array.from(event)), [
    ['Hello there', 'Guest-1', false],
    ['Hello there.', 'Guest-1', true],
  ]);
  await context.azureSpeechTranscriber.stop();
});