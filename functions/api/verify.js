/**
 * Cloudflare Pages Function: /api/verify
 * POST { session_id: string }
 * Verifies a Stripe Checkout Session and returns a signed access token.
 *
 * Required Cloudflare Pages secrets (set in dashboard → Settings → Environment variables):
 *   STRIPE_SECRET_KEY   — sk_live_... or sk_test_...
 *   TOKEN_SECRET        — any long random string (>= 32 chars), e.g. openssl rand -hex 32
 */

export async function onRequestPost(context) {
  const { request, env } = context;

  // CORS headers
  const headers = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': 'https://atlassports.ai',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };

  try {
    const body = await request.json();
    const sessionId = body?.session_id;

    if (!sessionId || typeof sessionId !== 'string' || !/^cs_(test|live)_/.test(sessionId)) {
      return new Response(JSON.stringify({ error: 'Invalid session_id' }), { status: 400, headers });
    }

    if (!env.STRIPE_SECRET_KEY) {
      return new Response(JSON.stringify({ error: 'Server misconfiguration' }), { status: 500, headers });
    }

    // Retrieve the checkout session from Stripe
    const stripeResp = await fetch(
      `https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(sessionId)}`,
      {
        headers: {
          Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
        },
      }
    );

    if (!stripeResp.ok) {
      return new Response(JSON.stringify({ error: 'Stripe lookup failed' }), { status: 502, headers });
    }

    const session = await stripeResp.json();

    // Must be paid/complete
    if (session.payment_status !== 'paid' && session.status !== 'complete') {
      return new Response(JSON.stringify({ error: 'Payment not complete' }), { status: 402, headers });
    }

    const email = session.customer_details?.email || session.customer_email || '';
    const customerId = session.customer || '';

    // Issue a signed access token: HMAC-SHA256 over "email|customerId|expires"
    // 30-day expiry for one-time payments; subscriptions should use webhooks for revocation
    const expires = Date.now() + 30 * 24 * 60 * 60 * 1000;
    const payload = `${email}|${customerId}|${expires}`;
    const sig = await hmacSign(payload, env.TOKEN_SECRET || 'dev-secret-change-me');

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
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}
