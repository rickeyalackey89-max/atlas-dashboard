const ALLOWED_ORIGIN = 'https://atlassports.ai';
const SECURITY_EVENT_TTL_SECONDS = 60 * 60 * 24 * 30;

const DATASETS = {
  dashboard: {
    kvKey: 'premium:nba:dashboard:latest',
    assetPath: '/data/cloudflare_payload.json',
  },
};

export async function onRequestGet(context) {
  const { request, env } = context;
  const headers = apiHeaders();
  const url = new URL(request.url);
  const dataset = (url.searchParams.get('dataset') || 'dashboard').toLowerCase();
  const spec = DATASETS[dataset];

  if (!spec) {
    return json({ ok: false, error: 'Unknown premium dataset.' }, 400, headers);
  }

  if (!env.SECRET_TOKEN) {
    context.waitUntil(logSecurityEvent(context, request, 'server_misconfigured', { dataset }));
    return json({ ok: false, error: 'Server misconfiguration.' }, 500, headers);
  }

  const auth = await verifyRequestToken(request, env.SECRET_TOKEN);
  if (!auth.ok) {
    context.waitUntil(logSecurityEvent(context, request, 'premium_auth_failed', { dataset, reason: auth.reason }));
    return json({ ok: false, error: 'Premium access required.' }, 401, headers);
  }

  const fingerprint = await requestFingerprint(request, env.SECRET_TOKEN);
  if (await isCanaryFlagged(env, fingerprint)) {
    context.waitUntil(logSecurityEvent(context, request, 'premium_blocked_canary', { dataset, email: auth.email }));
    return json({ ok: false, error: 'Request blocked.' }, 403, headers);
  }

  const rate = await checkRateLimit(context, request, auth, dataset, fingerprint);
  if (!rate.ok) {
    context.waitUntil(logSecurityEvent(context, request, 'premium_rate_limited', {
      dataset,
      email: auth.email,
      count: rate.count,
      limit: rate.limit,
    }));
    return json({ ok: false, error: 'Rate limit exceeded.' }, 429, headers);
  }

  const loaded = await loadDataset(context, spec);
  if (!loaded.ok) {
    context.waitUntil(logSecurityEvent(context, request, 'premium_dataset_missing', { dataset }));
    return json({ ok: false, error: 'Premium data unavailable.' }, 502, headers);
  }

  const watermark = await buildWatermark(env.SECRET_TOKEN, auth, dataset);
  const data = loaded.data && typeof loaded.data === 'object' ? loaded.data : {};
  data._atlas_security = {
    dataset,
    source: loaded.source,
    watermark_id: watermark,
    issued_at_utc: new Date().toISOString(),
    canary_url: `/api/canary?wm=${encodeURIComponent(watermark)}&d=${encodeURIComponent(dataset)}`,
  };
  applyWatermark(data, watermark);

  context.waitUntil(logSecurityEvent(context, request, 'premium_dataset_served', {
    dataset,
    email: auth.email,
    customerId: auth.customerId,
    source: loaded.source,
    rate_count: rate.count,
    watermark_id: watermark,
  }));

  return json(data, 200, headers);
}

export async function onRequestOptions() {
  return new Response(null, { status: 204, headers: apiHeaders() });
}

function apiHeaders(extra) {
  return {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Atlas-Token',
    'Cache-Control': 'private, no-store, max-age=0',
    'Vary': 'Authorization',
    'X-Robots-Tag': 'noindex, nofollow, noai, noimageai',
    ...(extra || {}),
  };
}

function json(body, status, headers) {
  return new Response(JSON.stringify(body), { status, headers });
}

async function verifyRequestToken(request, secret) {
  const token = getBearerToken(request);
  if (!token) return { ok: false, reason: 'missing_token' };

  let payload;
  try {
    payload = JSON.parse(atob(token));
  } catch {
    return { ok: false, reason: 'malformed_token' };
  }

  const email = String(payload.email || '').trim().toLowerCase();
  const customerId = String(payload.customerId || '').trim();
  const expires = Number(payload.expires || 0);
  const sig = String(payload.sig || '');

  if (!email || !customerId || !expires || !sig) return { ok: false, reason: 'incomplete_token' };
  if (Date.now() > expires) return { ok: false, reason: 'expired_token' };

  const expected = await hmacSign(`${email}|${customerId}|${expires}`, secret);
  if (!(await safeCompare(sig, expected))) return { ok: false, reason: 'bad_signature' };

  return { ok: true, email, customerId, expires };
}

function getBearerToken(request) {
  const auth = request.headers.get('Authorization') || '';
  if (/^Bearer\s+/i.test(auth)) return auth.replace(/^Bearer\s+/i, '').trim();
  return (request.headers.get('X-Atlas-Token') || '').trim();
}

async function loadDataset(context, spec) {
  const kv = context.env.ATLAS_PREMIUM_KV;
  if (kv && typeof kv.get === 'function') {
    const raw = await kv.get(spec.kvKey);
    if (raw) {
      try {
        return { ok: true, source: 'kv', data: JSON.parse(raw) };
      } catch {
        return { ok: false };
      }
    }
  }

  const assetUrl = new URL(spec.assetPath, context.request.url);
  let resp;
  if (context.env.ASSETS && typeof context.env.ASSETS.fetch === 'function') {
    resp = await context.env.ASSETS.fetch(new Request(assetUrl.toString(), { method: 'GET' }));
  } else {
    resp = await fetch(assetUrl.toString(), { method: 'GET' });
  }
  if (!resp.ok) return { ok: false };
  try {
    const data = await resp.json();
    return { ok: true, source: 'public_asset_fallback', data };
  } catch {
    return { ok: false };
  }
}

async function checkRateLimit(context, request, auth, dataset, fingerprint) {
  const kv = context.env.ATLAS_SECURITY_KV;
  const limit = Number(context.env.ATLAS_PREMIUM_RATE_LIMIT_PER_MINUTE || 120);
  if (!kv || typeof kv.get !== 'function' || !Number.isFinite(limit) || limit <= 0) {
    return { ok: true, count: 0, limit };
  }

  const minute = Math.floor(Date.now() / 60000);
  const subject = auth.customerId === 'admin' ? auth.email : auth.customerId;
  const keyHash = await hmacSign(`${subject}|${fingerprint}|${dataset}|${minute}`, context.env.SECRET_TOKEN);
  const key = `rl:premium:${minute}:${keyHash.slice(0, 32)}`;
  const current = Number(await kv.get(key) || 0) + 1;
  await kv.put(key, String(current), { expirationTtl: 180 });
  return { ok: current <= limit, count: current, limit };
}

async function isCanaryFlagged(env, fingerprint) {
  const kv = env.ATLAS_SECURITY_KV;
  if (!kv || typeof kv.get !== 'function') return false;
  return Boolean(await kv.get(`security:canary-fingerprint:${fingerprint}`));
}

async function logSecurityEvent(context, request, event, details) {
  const kv = context.env.ATLAS_SECURITY_KV;
  const record = {
    event,
    at: new Date().toISOString(),
    ip: request.headers.get('CF-Connecting-IP') || '',
    country: request.headers.get('CF-IPCountry') || '',
    colo: request.cf && request.cf.colo ? request.cf.colo : '',
    user_agent: request.headers.get('User-Agent') || '',
    path: new URL(request.url).pathname,
    details: details || {},
  };

  if (!kv || typeof kv.put !== 'function') {
    console.log(JSON.stringify(record));
    return;
  }

  const day = record.at.slice(0, 10);
  const random = crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2);
  await kv.put(`security:events:${day}:${Date.now()}:${random}`, JSON.stringify(record), {
    expirationTtl: SECURITY_EVENT_TTL_SECONDS,
  });
}

async function requestFingerprint(request, secret) {
  const raw = [
    request.headers.get('CF-Connecting-IP') || '',
    request.headers.get('User-Agent') || '',
    request.headers.get('Accept-Language') || '',
  ].join('|');
  const digest = await hmacSign(raw, secret);
  return digest.slice(0, 32);
}

async function buildWatermark(secret, auth, dataset) {
  const sessionBucket = Math.floor(auth.expires / (1000 * 60 * 60 * 24));
  const digest = await hmacSign(`${auth.email}|${auth.customerId}|${dataset}|${sessionBucket}`, secret);
  return `atl-${digest.slice(0, 20)}`;
}

function applyWatermark(data, watermark) {
  const collections = [
    'system',
    'system_winprob',
    'windfall',
    'windfall_winprob',
    'demonhunter',
    'marketed_slips',
    'all_legs',
  ];
  for (const name of collections) {
    const rows = Array.isArray(data[name]) ? data[name] : [];
    for (const row of rows) {
      if (row && typeof row === 'object') row.atlas_watermark = watermark;
    }
  }
}

async function safeCompare(a, b) {
  const left = String(a || '');
  const right = String(b || '');
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return diff === 0;
}

async function hmacSign(message, secret) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const sigBuffer = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
  return Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
