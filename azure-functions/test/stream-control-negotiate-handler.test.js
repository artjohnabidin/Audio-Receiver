import assert from 'node:assert/strict';
import test from 'node:test';
import { createStreamControlNegotiateHandler } from '../src/stream-control-negotiate-handler.js';

const origin = 'https://audio.example.com';
const env = { ALLOWED_ORIGINS: origin };
const quiet = { error() {} };
const negotiateUrl = 'https://function.example.com/api/stream-control/negotiate';

function request({ query = '?eventId=event-1&role=listener', headers = {}, method = 'GET' } = {}) {
  return new Request(`${negotiateUrl}${query}`, {
    method,
    headers: { authorization: 'Bearer id-token', origin, ...headers },
  });
}

test('issues a group-scoped Web PubSub client URL', async () => {
  let issued;
  const handler = createStreamControlNegotiateHandler({
    env,
    verifyToken: async (token) => {
      assert.equal(token, 'id-token');
      return 'user-oid';
    },
    getClientAccessToken: async (options) => {
      issued = options;
      return { url: 'wss://pubsub.example.com/client/hubs/streamcontrol?access_token=t' };
    },
    log: quiet,
  });

  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    url: 'wss://pubsub.example.com/client/hubs/streamcontrol?access_token=t',
    group: 'event.event-1',
    expiresIn: 3600,
  });
  assert.deepEqual(issued, {
    userId: 'listener:user-oid',
    groups: ['event.event-1'],
    roles: ['webpubsub.joinLeaveGroup.event.event-1', 'webpubsub.sendToGroup.event.event-1'],
    expirationTimeInMinutes: 60,
  });
  assert.equal(response.headers.get('access-control-allow-origin'), origin);
  assert.equal(response.headers.get('cache-control'), 'no-store');
});

test('allows native clients without an Origin header', async () => {
  const handler = createStreamControlNegotiateHandler({
    env,
    verifyToken: async () => 'user-oid',
    getClientAccessToken: async () => ({ url: 'wss://pubsub.example.com/x' }),
    log: quiet,
  });
  const response = await handler(new Request(`${negotiateUrl}?eventId=event-1&role=broadcaster`, {
    headers: { authorization: 'Bearer id-token' },
  }));

  assert.equal(response.status, 200);
  assert.equal(response.headers.get('access-control-allow-origin'), null);
});

test('rejects untrusted browser origins', async () => {
  const handler = createStreamControlNegotiateHandler({ env, log: quiet });
  const response = await handler(request({ headers: { origin: 'https://untrusted.example' } }));
  assert.equal(response.status, 403);
});

test('rejects missing or invalid credentials without issuing tokens', async () => {
  let issued = false;
  const handler = createStreamControlNegotiateHandler({
    env,
    verifyToken: async () => { throw new Error('bad token'); },
    getClientAccessToken: async () => { issued = true; },
    log: quiet,
  });

  assert.equal((await handler(request({ headers: { authorization: '' } }))).status, 401);
  assert.equal((await handler(request())).status, 401);
  assert.equal(issued, false);
});

test('rejects invalid event ids and roles', async () => {
  const handler = createStreamControlNegotiateHandler({
    env,
    verifyToken: async () => 'user-oid',
    log: quiet,
  });

  assert.equal((await handler(request({ query: '?eventId=$bad&role=listener' }))).status, 400);
  assert.equal((await handler(request({ query: '?eventId=event-1&role=admin' }))).status, 400);
});

test('answers CORS preflight', async () => {
  const handler = createStreamControlNegotiateHandler({ env, log: quiet });
  const response = await handler(request({ method: 'OPTIONS' }));
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('access-control-allow-methods'), 'GET, OPTIONS');
});

test('hides Web PubSub configuration failures', async () => {
  const handler = createStreamControlNegotiateHandler({
    env,
    verifyToken: async () => 'user-oid',
    log: quiet,
  });
  const response = await handler(request());
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'Stream control service is unavailable' });
});
