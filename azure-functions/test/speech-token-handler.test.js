import assert from 'node:assert/strict';
import test from 'node:test';
import { createSpeechTokenHandler } from '../src/speech-token-handler.js';

const origin = 'https://audio.example.com';
const env = {
  ALLOWED_ORIGINS: origin,
  AZURE_SPEECH_KEY: 'server-only-key',
  AZURE_SPEECH_REGION: 'japaneast',
};
const authorizedRequest = () => new Request('https://function.example.com/api/speech/token', {
  method: 'POST',
  headers: { authorization: 'Bearer valid-access-token', origin },
});

test('returns an Azure Speech token with the client contract', async () => {
  let upstreamRequest;
  const handler = createSpeechTokenHandler({
    env,
    verifyToken: async (token) => assert.equal(token, 'valid-access-token'),
    fetchImpl: async (url, options) => {
      upstreamRequest = { url, options };
      return new Response('short-lived-speech-token', { status: 200 });
    },
    log: { error() {} },
  });

  const response = await handler(authorizedRequest());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    token: 'short-lived-speech-token',
    region: 'japaneast',
    expiresIn: 540,
  });
  assert.equal(upstreamRequest.url, 'https://japaneast.api.cognitive.microsoft.com/sts/v1.0/issueToken');
  assert.equal(upstreamRequest.options.headers['Ocp-Apim-Subscription-Key'], 'server-only-key');
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'), origin);
});

test('rejects unauthenticated requests without calling Azure', async () => {
  let called = false;
  const handler = createSpeechTokenHandler({
    env,
    fetchImpl: async () => { called = true; },
    log: { error() {} },
  });
  const request = authorizedRequest();
  request.headers.delete('authorization');

  const response = await handler(request);
  assert.equal(response.status, 401);
  assert.equal(called, false);
});

test('rejects origins outside the allowlist', async () => {
  const handler = createSpeechTokenHandler({ env, log: { error() {} } });
  const request = new Request('https://function.example.com/api/speech/token', {
    method: 'POST',
    headers: { authorization: 'Bearer valid-access-token', origin: 'https://untrusted.example' },
  });

  assert.equal((await handler(request)).status, 403);
});

test('returns an empty successful response to CORS preflight', async () => {
  const handler = createSpeechTokenHandler({ env, log: { error() {} } });
  const request = new Request('https://function.example.com/api/speech/token', {
    method: 'OPTIONS',
    headers: { origin },
  });
  const response = await handler(request);

  assert.equal(response.status, 204);
  assert.equal(response.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
});

test('does not expose upstream details when Azure rejects token issuance', async () => {
  const handler = createSpeechTokenHandler({
    env,
    verifyToken: async () => {},
    fetchImpl: async () => new Response('sensitive upstream response', { status: 401 }),
    log: { error() {} },
  });

  const response = await handler(authorizedRequest());
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: 'Speech token service is unavailable' });
});