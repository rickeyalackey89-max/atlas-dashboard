/**
 * Cloudflare Pages Function: /api/login
 * POST { email: string, password: string }
 *
 * Two auth paths — both require email + password:
 *
 * 1. ADMIN — email+password match ADMIN_EMAIL+ADMIN_PASSWORD → 365-day token
 *    Required env vars: ADMIN_EMAIL, ADMIN_PASSWORD, SECRET_TOKEN
 *
 * 2. SUBSCRIBER — email+password verified against Stripe customer metadata
 *    - Looks up Stripe customer by email, confirms active subscription
 *    - Verifies PBKDF2-SHA256 hash stored in customer.metadata.atlas_pw_hash
 *    - Issues a 30-day token on success
 *    Required env vars: STRIPE_SECRET_KEY, SECRET_TOKEN
 *
 * Password hashing: PBKDF2-SHA256, 100k iterations, email-as-salt (deterministic,
 * no separate salt storage needed since Stripe metadata has no extra field to spare).
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
    const pass  = (body?.password || '');

    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return new Response(JSON.stringify({ error: 'A valid email address is required.' }), { status: 400, headers });
    }
    if (!pass) {
      return new Response(JSON.stringify({ error: 'Password is required.' }), { status: 400, headers });
    }

    // ── Path 1: Admin bypass ────────────────────────────────────────────────────
    const adminEmail = (env.ADMIN_EMAIL || '').trim().toLowerCase();
    const adminPass  = (env.ADMIN_PASSWORD || '').trim();

    if (adminEmail && adminPass) {
      const emailOk = await safeCompare(email, adminEmail);
      const passOk  = await safeCompare(pass,  adminPass);
      if (emailOk && passOk) {
        const expires = Date.now() + 365 * 24 * 60 * 60 * 1000;
        const token   = await issueToken(email, 'admin', expires, env.SECRET_TOKEN);
        return new Response(JSON.stringify({ ok: true, token, email }), { status: 200, headers });
      }
    }

    // ── Path 2: Subscriber ──────────────────────────────────────────────────────
    if (!env.STRIPE_SECRET_KEY) {
      return new Response(JSON.stringify({ error: 'Server misconfiguration.' }), { status: 500, headers });
    }

    // Find Stripe customer by email
    const searchResp = await fetch(
      `https://api.stripe.com/v1/customers?email=${encodeURIComponent(email)}&limit=5`,
      { headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` } }
    );
    if (!searchResp.ok) {
      return new Response(JSON.stringify({ error: 'Unable to verify subscription. Please try again.' }), { status: 502, headers });
    }
    const searchData = await searchResp.json();
    const customers  = searchData.data || [];

    // Find first customer with an active subscription
    let activeCustomer = null;
    for (const cust of customers) {
      const subResp = await fetch(
        `https://api.stripe.com/v1/subscriptions?customer=${cust.id}&status=active&limit=1`,
        { headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` } }
      );
      if (!subResp.ok) continue;
      const subData = await subResp.json();
      if (subData.data && subData.data.length > 0) {
        activeCustomer = cust;
        break;
      }
    }

    if (!activeCustomer) {
      return new Response(
        JSON.stringify({ error: 'No active subscription found for that email.' }),
        { status: 401, headers }
      );
    }

    // Verify password hash stored in Stripe metadata
    const storedHash = activeCustomer.metadata?.atlas_pw_hash || '';
    if (!storedHash) {
      return new Response(
        JSON.stringify({ error: 'No password set for this account. Please create your password via your welcome link, or contact support.' }),
        { status: 401, headers }
      );
    }

    const inputHash = await pbkdf2Hash(pass, email);
    const hashMatch = await safeCompare(inputHash, storedHash);
    if (!hashMatch) {
      return new Response(
        JSON.stringify({ error: 'Incorrect password.' }),
        { status: 401, headers }
      );
    }

    // Issue 30-day token
    const expires = Date.now() + 30 * 24 * 60 * 60 * 1000;
    const token   = await issueToken(email, activeCustomer.id, expires, env.SECRET_TOKEN);
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

/**
 * PBKDF2-SHA256 with 100k iterations, using email as the salt.
 * Deterministic: same email+password always produces the same hash.
 */
async function pbkdf2Hash(password, email) {
  const enc = new TextEncoder();
  const keyMaterial = await crypto.subtle.importKey(
    'raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: enc.encode(email.toLowerCase()), iterations: 100000, hash: 'SHA-256' },
    keyMaterial, 256
  );
  return Array.from(new Uint8Array(bits)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function safeCompare(a, b) {
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

