const ALLOWED_ORIGIN = 'https://atlassports.ai';
const SECURITY_EVENT_TTL_SECONDS = 60 * 60 * 24 * 30;

export async function onRequestGet(context) {
  const { request, env } = context;
  const url = new URL(request.url);
  const wm = (url.searchParams.get('wm') || '').slice(0, 80);
  const dataset = (url.searchParams.get('d') || '').slice(0, 80);
  const secret = env.SECRET_TOKEN || 'canary-fallback';
  const fingerprint = await requestFingerprint(request, secret);
  const record = {
    event: 'canary_hit',
    at: new Date().toISOString(),
    ip: request.headers.get('CF-Connecting-IP') || '',
    country: request.headers.get('CF-IPCountry') || '',
    user_agent: request.headers.get('User-Agent') || '',
    path: url.pathname,
    watermark_id: wm,
    dataset,
    fingerprint,
  };

  const kv = env.ATLAS_SECURITY_KV;
  if (kv && typeof kv.put === 'function') {
    const day = record.at.slice(0, 10);
    const random = crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2);
    await Promise.all([
      kv.put(`security:canary-fingerprint:${fingerprint}`, JSON.stringify(record), {
        expirationTtl: SECURITY_EVENT_TTL_SECONDS,
      }),
      wm
        ? kv.put(`security:canary-watermark:${wm}`, JSON.stringify(record), {
            expirationTtl: SECURITY_EVENT_TTL_SECONDS,
          })
        : Promise.resolve(),
      kv.put(`security:events:${day}:${Date.now()}:${random}`, JSON.stringify(record), {
        expirationTtl: SECURITY_EVENT_TTL_SECONDS,
      }),
    ]);
  } else {
    console.log(JSON.stringify(record));
  }

  return new Response('Not found', {
    status: 404,
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
      'Cache-Control': 'no-store',
      'X-Robots-Tag': 'noindex, nofollow, noai, noimageai',
    },
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
