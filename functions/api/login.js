/**
 * Cloudflare Pages Function: /api/login
 *
 * Two auth paths:
 *
 * 1. SUBSCRIBER — POST { email }
 *    Looks up the email in Stripe. If there is an active subscription, issues a
 *    fresh 30-day token (same format as /api/verify after checkout).
 *    Required env vars: STRIPE_SECRET_KEY, SECRET_TOKEN
 *
 * 2. ADMIN — POST { email, password }
 *    If the email + password match ADMIN_EMAIL + ADMIN_PASSWORD, issues a 365-day
 *    admin token without touching Stripe.
 *    Required env vars: ADMIN_EMAIL, ADMIN_PASSWORD, SECRET_TOKEN
 */

export async function onRequestPost(context) {
  const { request, env } = context;

  const headers = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': 'https://atlassports.ai',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };

  try {
    const body  = await request.json();
    const email = (body?.email    || '').trim().toLowerCase();
    const pass  = (body?.password || '').trim();

    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return new Response(JSON.stringify({ error: 'A valid email address is required.' }), { status: 400, headers });
    }

    // ── Path 1: Admin bypass (email + password provided) ──────────────────────
    const adminEmail = (env.ADMIN_EMAIL || '').trim().toLowerCase();
    const adminPass  = (env.ADMIN_PASSWORD || '').trim();

    if (pass && adminEmail && adminPass) {
      const emailOk = await safeCompare(email, adminEmail);
      const passOk  = await safeCompare(pass,  adminPass);
      if (emailOk && passOk) {
        const expires = Date.now() + 365 * 24 * 60 * 60 * 1000;
        const token   = await issueToken(email, 'admin', expires, env.SECRET_TOKEN);
        return new Response(JSON.stringify({ ok: true, token, email }), { status: 200, headers });
      }
      // Wrong admin credentials — fall through to Stripe check (don't reveal admin exists)
    }

    // ── Path 2: Subscriber — look up active subscription in Stripe ────────────
    if (!env.STRIPE_SECRET_KEY) {
      return new Response(JSON.stringify({ error: 'Server misconfiguration.' }), { status: 500, headers });
    }

    // Search Stripe customers by email
    const searchResp = await fetch(
      `https://api.stripe.com/v1/customers?email=${encodeURIComponent(email)}&limit=5`,
      { headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` } }
    );
    if (!searchResp.ok) {
      return new Response(JSON.stringify({ error: 'Unable to verify subscription. Please try again.' }), { status: 502, headers });
    }
    const searchData = await searchResp.json();
    const customers  = (searchData.data || []);

    // Walk each customer and look for at least one active subscription
    let activeCustomerId = null;
    for (const cust of customers) {
      const subResp = await fetch(
        `https://api.stripe.com/v1/subscriptions?customer=${cust.id}&status=active&limit=1`,
        { headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` } }
      );
      if (!subResp.ok) continue;
      const subData = await subResp.json();
      if (subData.data && subData.data.length > 0) {
        activeCustomerId = cust.id;
        break;
      }
    }

    if (!activeCustomerId) {
      return new Response(
        JSON.stringify({ error: 'No active subscription found for that email. If you just subscribed, please wait a moment and try again.' }),
        { status: 401, headers }
      );
    }

    // Issue a fresh 30-day token (matches monthly billing cycle)
    const expires = Date.now() + 30 * 24 * 60 * 60 * 1000;
    const token   = await issueToken(email, activeCustomerId, expires, env.SECRET_TOKEN);
    return new Response(JSON.stringify({ ok: true, token, email }), { status: 200, headers });

  } catch (err) {
    return new Response(JSON.stringify({ error: 'Internal error.' }), { status: 500, headers });
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

async function issueToken(email, customerId, expires, secret) {
  const payload = `${email}|${customerId}|${expires}`;
  const sig     = await hmacSign(payload, secret || 'dev-secret-change-me');
  return btoa(JSON.stringify({ email, customerId, expires, sig }));
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
