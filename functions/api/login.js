/**
 * Cloudflare Pages Function: /api/login
 * POST { email: string, password: string }
 * For owner/admin access without going through Stripe.
 *
 * Required Cloudflare Pages env vars:
 *   ADMIN_PASSWORD  — the owner password (set in CF Pages → Settings → Env vars)
 *   SECRET_TOKEN    — same secret used by verify.js for token signing
 *
 * Returns same token format as /api/verify so the dashboard unlocks identically.
 */

export async function onRequestPost(context) {
  const { request, env } = context;

  const headers = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': 'https://atlassports.ai',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };

  try {
    const body = await request.json();
    const email    = (body?.email    || '').trim().toLowerCase();
    const password = (body?.password || '').trim();

    if (!email || !password) {
      return new Response(JSON.stringify({ error: 'Email and password required' }), { status: 400, headers });
    }

    // Basic email format check
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return new Response(JSON.stringify({ error: 'Invalid email' }), { status: 400, headers });
    }

    const adminPassword = env.ADMIN_PASSWORD;
    if (!adminPassword) {
      return new Response(JSON.stringify({ error: 'Server misconfiguration' }), { status: 500, headers });
    }

    // Constant-time comparison to avoid timing attacks
    const match = await safeCompare(password, adminPassword);
    if (!match) {
      // Generic message — don't reveal whether email or password was wrong
      return new Response(JSON.stringify({ error: 'Invalid credentials' }), { status: 401, headers });
    }

    // Issue a 365-day token for admin (same format as Stripe-issued tokens)
    const expires = Date.now() + 365 * 24 * 60 * 60 * 1000;
    const customerId = 'admin';
    const payload = `${email}|${customerId}|${expires}`;
    const sig = await hmacSign(payload, env.SECRET_TOKEN || 'dev-secret-change-me');
    const token = btoa(JSON.stringify({ email, customerId, expires, sig }));

    return new Response(JSON.stringify({ ok: true, token, email }), { status: 200, headers });
  } catch (err) {
    return new Response(JSON.stringify({ error: 'Internal error' }), { status: 500, headers });
  }
}

export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': 'https://atlassports.ai',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    },
  });
}

async function safeCompare(a, b) {
  // Encode both to same length via HMAC so timing is constant regardless of length difference
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', encoder.encode('compare-key'),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const [sigA, sigB] = await Promise.all([
    crypto.subtle.sign('HMAC', key, encoder.encode(a)),
    crypto.subtle.sign('HMAC', key, encoder.encode(b)),
  ]);
  const arrA = new Uint8Array(sigA);
  const arrB = new Uint8Array(sigB);
  let diff = 0;
  for (let i = 0; i < arrA.length; i++) diff |= arrA[i] ^ arrB[i];
  return diff === 0;
}

async function hmacSign(message, secret) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const sigBuffer = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
  return Array.from(new Uint8Array(sigBuffer))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}
