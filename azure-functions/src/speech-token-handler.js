import { createRemoteJWKSet, jwtVerify } from 'jose';

const jwksCache = new Map();

function getJwks(url) {
  const key = url.toString();
  if (!jwksCache.has(key)) jwksCache.set(key, createRemoteJWKSet(url));
  return jwksCache.get(key);
}

async function verifySupabaseToken(token, env) {
  const supabaseUrl = env.SUPABASE_URL?.replace(/\/$/, '');
  if (!supabaseUrl) throw new Error('Supabase token verification is not configured');

  const issuer = `${supabaseUrl}/auth/v1`;
  const audience = env.SUPABASE_JWT_AUDIENCE || 'authenticated';
  let key;
  let algorithms;

  if (env.SUPABASE_JWT_SECRET) {
    key = new TextEncoder().encode(env.SUPABASE_JWT_SECRET);
    algorithms = ['HS256'];
  } else {
    const jwksUrl = env.SUPABASE_JWKS_URL || `${issuer}/.well-known/jwks.json`;
    key = getJwks(new URL(jwksUrl));
  }

  const { payload } = await jwtVerify(token, key, {
    issuer,
    audience,
    ...(algorithms ? { algorithms } : {}),
  });
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Supabase token has no subject');
  }
}

function corsHeaders(origin, env) {
  const allowedOrigins = (env.ALLOWED_ORIGINS || '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  if (!origin || !allowedOrigins.includes(origin)) return null;

  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
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

export function createSpeechTokenHandler({
  env = process.env,
  fetchImpl = globalThis.fetch,
  verifyToken = verifySupabaseToken,
  log = console,
} = {}) {
  return async function speechTokenHandler(request) {
    // const headers = corsHeaders(request.headers.get('origin'), env);
    const origin = request.headers.get('origin');
    const allowedOrigins = (env.ALLOWED_ORIGINS || '')
      .split(',')
      .map(value => value.trim())
      .filter(Boolean);

    console.error('CORS DEBUG', {
      method: request.method,
      origin,
      allowedOrigins,
      matches: allowedOrigins.includes(origin),
    });

    const headers = corsHeaders(origin, env);

    if (!headers) {
      return jsonResponse({ error: 'Origin is not allowed' }, 403, {});
    }
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST') return jsonResponse({ error: 'Method not allowed' }, 405, headers);

    console.error('STEP 1: CORS passed');

    const authorization = request.headers.get('authorization') || '';
    console.error('STEP 2: Authorization header present:', !!authorization);

    const match = /^Bearer\s+(\S+)$/i.exec(authorization);
    if (!match) return jsonResponse({ error: 'Authentication required' }, 401, headers);
    console.error('STEP 3: JWT verification starting');

    try {
      await verifyToken(match[1], env);
      console.error('STEP 4: JWT verification passed');
    } catch (error) {
      console.error('JWT verification failed:', error);
      log.error('Supabase JWT verification failed', {
        name: error?.name,
        code: error?.code,
        message: error?.message,
      });
      return jsonResponse({ error: 'Authentication failed' }, 401, headers);
    }
    console.error('STEP 5: Checking Azure Speech configuration');

    const key = env.AZURE_SPEECH_KEY;
    const region = env.AZURE_SPEECH_REGION;
    if (!key || !region || !/^[a-z0-9-]+$/i.test(region)) {
      log.error('Azure Speech token endpoint is not configured');
      return jsonResponse({ error: 'Speech token service is unavailable' }, 503, headers);
    }

    try {
      const response = await fetchImpl(
        `https://${region}.api.cognitive.microsoft.com/sts/v1.0/issueToken`,
        {
          method: 'POST',
          headers: { 'Ocp-Apim-Subscription-Key': key },
          signal: AbortSignal.timeout(10000),
        },
      );
      if (!response.ok) {
        log.error(`Azure Speech token request failed with HTTP ${response.status}`);
        return jsonResponse({ error: 'Speech token service is unavailable' }, 502, headers);
      }

      const token = (await response.text()).trim();
      if (!token) {
        log.error('Azure Speech returned an empty authorization token');
        return jsonResponse({ error: 'Speech token service is unavailable' }, 502, headers);
      }

      return jsonResponse({ token, region, expiresIn: 540 }, 200, headers);
    } catch (error) {
      log.error('Azure Speech token request failed', error);
      return jsonResponse({ error: 'Speech token service is unavailable' }, 502, headers);
    }
  };
}