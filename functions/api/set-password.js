/**
 * Cloudflare Pages Function: /api/set-password
 * POST { session_id: string, password: string }
 *
 * Called from the welcome page immediately after a successful Stripe checkout.
 * Validates the checkout session with Stripe, then PBKDF2-hashes the chosen
 * password and stores it in the Stripe customer's metadata as `atlas_pw_hash`.
 * Returns the same access token issued by /api/verify so the user is logged in
 * immediately after creating their password.
 *
 * Required Cloudflare Pages env vars:
 *   STRIPE_SECRET_KEY  — sk_live_... or sk_test_...
 *   SECRET_TOKEN       — same signing secret used by verify.js
 */

export async function onRequestPost(context) {
  const { request, env } = context;

  const headers = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': 'https://atlassports.ai',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };

  try {
    const body      = await request.json();
    const sessionId = (body?.session_id || '').trim();
    const password  = body?.password || '';

    if (!sessionId || !/^cs_(test|live)_/.test(sessionId)) {
      return new Response(JSON.stringify({ error: 'Invalid session ID.' }), { status: 400, headers });
    }
    if (!password || password.length < 8) {
      return new Response(JSON.stringify({ error: 'Password must be at least 8 characters.' }), { status: 400, headers });
    }

    if (!env.STRIPE_SECRET_KEY) {
      return new Response(JSON.stringify({ error: 'Server misconfiguration.' }), { status: 500, headers });
    }

    // Verify the Stripe checkout session
    const sessionResp = await fetch(
      `https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(sessionId)}`,
      { headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` } }
    );
    if (!sessionResp.ok) {
      return new Response(JSON.stringify({ error: 'Could not verify your payment session.' }), { status: 502, headers });
    }
    const session = await sessionResp.json();

    if (session.payment_status !== 'paid' && session.status !== 'complete') {
      return new Response(JSON.stringify({ error: 'Payment not complete.' }), { status: 402, headers });
    }

    const email      = (session.customer_details?.email || session.customer_email || '').toLowerCase().trim();
    const customerId = session.customer || '';

    if (!email || !customerId) {
      return new Response(JSON.stringify({ error: 'Could not retrieve account details from your session.' }), { status: 400, headers });
    }

    // Hash the password and store it in Stripe customer metadata
    const pwHash = await pbkdf2Hash(password, email);

    const updateResp = await fetch(
      `https://api.stripe.com/v1/customers/${encodeURIComponent(customerId)}`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: `metadata[atlas_pw_hash]=${encodeURIComponent(pwHash)}`,
      }
    );
    if (!updateResp.ok) {
      return new Response(JSON.stringify({ error: 'Failed to save your password. Please try again.' }), { status: 502, headers });
    }

    // Issue 30-day access token (same format as verify.js)
    const expires = Date.now() + 30 * 24 * 60 * 60 * 1000;
    const token   = await issueToken(email, customerId, expires, env.SECRET_TOKEN);

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

async function issueToken(email, customerId, expires, secret) {
  const payload = `${email}|${customerId}|${expires}`;
  const sig     = await hmacSign(payload, secret || 'dev-secret-change-me');
  return btoa(JSON.stringify({ email, customerId, expires, sig }));
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
