import { WebPubSubServiceClient } from '@azure/web-pubsub';
import { createRemoteJWKSet, jwtVerify } from 'jose';

const DEFAULT_HUB = 'streamcontrol';
const TOKEN_LIFETIME_MINUTES = 60;
const EVENT_ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
const HUB_PATTERN = /^[A-Za-z][A-Za-z0-9_]{0,127}$/;
const CLIENT_ROLES = new Set(['listener', 'broadcaster']);

const jwksCache = new Map();

function getJwks(url) {
  if (!jwksCache.has(url)) jwksCache.set(url, createRemoteJWKSet(new URL(url)));
  return jwksCache.get(url);
}

export function streamControlGroup(eventId) {
  return `event.${eventId}`;
}

async function verifyMicrosoftIdToken(token, env) {
  const tenantId = env.MICROSOFT_TENANT_ID;
  const clientId = env.MICROSOFT_CLIENT_ID;
  if (!tenantId || !clientId) throw new Error('Microsoft token verification is not configured');

  const { payload } = await jwtVerify(
    token,
    getJwks(`https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`),
    {
      issuer: `https://login.microsoftonline.com/${tenantId}/v2.0`,
      audience: clientId,
      algorithms: ['RS256'],
    },
  );
  const subject = payload.oid || payload.sub;
  if (typeof subject !== 'string' || subject.length === 0) {
    throw new Error('Microsoft token has no subject');
  }
  return subject;
}

function issueClientAccessToken(env, options) {
  const connectionString = env.WEB_PUBSUB_CONNECTION_STRING;
  if (!connectionString) throw new Error('Web PubSub is not configured');
  return new WebPubSubServiceClient(connectionString, hubName(env)).getClientAccessToken(options);
}

function hubName(env) {
  const hub = env.WEB_PUBSUB_HUB || DEFAULT_HUB;
  if (!HUB_PATTERN.test(hub)) throw new Error('Invalid Web PubSub hub name');
  return hub;
}

// Native clients send no Origin header; browser origins must be allowlisted.
function corsHeaders(origin, env) {
  if (!origin) return {};
  const allowedOrigins = (env.ALLOWED_ORIGINS || '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  if (!allowedOrigins.includes(origin)) return null;

  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
}

function jsonResponse(body, status, headers) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...headers,
      'Cache-Control': 'no-store',
      'Content-Type': 'application/json; charset=utf-8',
    },
  });
}

export function createStreamControlNegotiateHandler({
  env = process.env,
  verifyToken = verifyMicrosoftIdToken,
  getClientAccessToken = (options) => issueClientAccessToken(env, options),
  log = console,
} = {}) {
  return async function streamControlNegotiateHandler(request) {
    const headers = corsHeaders(request.headers.get('origin'), env);
    if (!headers) return jsonResponse({ error: 'Origin is not allowed' }, 403, {});
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'GET') return jsonResponse({ error: 'Method not allowed' }, 405, headers);

    const match = /^Bearer\s+(\S+)$/i.exec(request.headers.get('authorization') || '');
    if (!match) return jsonResponse({ error: 'Authentication required' }, 401, headers);

    const params = new URL(request.url).searchParams;
    const eventId = params.get('eventId') || '';
    const role = params.get('role') || '';
    if (!EVENT_ID_PATTERN.test(eventId) || !CLIENT_ROLES.has(role)) {
      return jsonResponse({ error: 'Invalid eventId or role' }, 400, headers);
    }

    let subject;
    try {
      subject = await verifyToken(match[1], env);
    } catch (error) {
      log.error('Microsoft ID token verification failed', { name: error?.name, code: error?.code });
      return jsonResponse({ error: 'Authentication failed' }, 401, headers);
    }

    const group = streamControlGroup(eventId);
    try {
      const { url } = await getClientAccessToken({
        userId: `${role}:${subject}`,
        groups: [group],
        roles: [`webpubsub.joinLeaveGroup.${group}`, `webpubsub.sendToGroup.${group}`],
        expirationTimeInMinutes: TOKEN_LIFETIME_MINUTES,
      });
      return jsonResponse({ url, group, expiresIn: TOKEN_LIFETIME_MINUTES * 60 }, 200, headers);
    } catch (error) {
      log.error('Web PubSub client token issuance failed', { name: error?.name, message: error?.message });
      return jsonResponse({ error: 'Stream control service is unavailable' }, 503, headers);
    }
  };
}
