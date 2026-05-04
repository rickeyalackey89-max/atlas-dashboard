/**
 * Cloudflare Pages Function: POST /api/create-checkout
 * Creates a Stripe Embedded Checkout Session (subscription mode).
 *
 * Required CF env vars:
 *   STRIPE_SECRET_KEY  — sk_live_...
 *   STRIPE_PRICE_ID    — price_xxx  (the $19.99/mo recurring price from Stripe Dashboard)
 */

const CORS = {
  'Access-Control-Allow-Origin': 'https://atlassports.ai',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export async function onRequestPost(context) {
  const { env } = context;

  try {
    if (!env.STRIPE_SECRET_KEY || !env.STRIPE_PRICE_ID) {
      return new Response(JSON.stringify({ error: 'Server misconfiguration: missing env vars' }), {
        status: 500, headers: { 'Content-Type': 'application/json', ...CORS },
      });
    }

    const params = new URLSearchParams({
      mode: 'subscription',
      ui_mode: 'embedded',
      'line_items[0][price]': env.STRIPE_PRICE_ID,
      'line_items[0][quantity]': '1',
      return_url: 'https://atlassports.ai/dashboard/welcome?session_id={CHECKOUT_SESSION_ID}',
    });

    const resp = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: params.toString(),
    });

    const text = await resp.text();
    let session;
    try {
      session = JSON.parse(text);
    } catch (e) {
      return new Response(JSON.stringify({ error: 'Stripe returned non-JSON: ' + text.slice(0, 300) }), {
        status: 502, headers: { 'Content-Type': 'application/json', ...CORS },
      });
    }

    if (!resp.ok || !session.client_secret) {
      var errMsg = (session.error && session.error.message) ? session.error.message : ('Stripe status ' + resp.status);
      return new Response(JSON.stringify({ error: errMsg }), {
        status: 502, headers: { 'Content-Type': 'application/json', ...CORS },
      });
    }

    return new Response(JSON.stringify({ clientSecret: session.client_secret }), {
      status: 200, headers: { 'Content-Type': 'application/json', ...CORS },
    });

  } catch (err) {
    return new Response(JSON.stringify({ error: 'Function exception: ' + (err && err.message ? err.message : String(err)) }), {
      status: 500, headers: { 'Content-Type': 'application/json', ...CORS },
    });
  }
}

export async function onRequestOptions() {
  return new Response(null, { status: 204, headers: CORS });
}
