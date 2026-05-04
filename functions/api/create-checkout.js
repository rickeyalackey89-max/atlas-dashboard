export async function onRequestPost(context) {
  var env = context.env;

  if (!env.STRIPE_SECRET_KEY || !env.STRIPE_PRICE_ID) {
    return new Response(JSON.stringify({ error: 'Missing env: STRIPE_SECRET_KEY or STRIPE_PRICE_ID' }), {
      status: 500, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }

  var body = 'mode=subscription&ui_mode=embedded'
    + '&line_items[0][price]=' + env.STRIPE_PRICE_ID
    + '&line_items[0][quantity]=1'
    + '&return_url=https%3A%2F%2Fatlassports.ai%2Fdashboard%2Fwelcome%3Fsession_id%3D%7BCHECKOUT_SESSION_ID%7D';

  var resp = await fetch('https://api.stripe.com/v1/checkout/sessions', {
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + env.STRIPE_SECRET_KEY,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body,
  });

  var text = await resp.text();
  var session = {};
  try { session = JSON.parse(text); } catch(e) {}

  if (!resp.ok) {
    var msg = (session.error && session.error.message) ? session.error.message : ('Stripe HTTP ' + resp.status + ': ' + text.slice(0, 200));
    return new Response(JSON.stringify({ error: msg }), {
      status: 502, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }

  if (!session.client_secret) {
    return new Response(JSON.stringify({ error: 'No client_secret in Stripe response' }), {
      status: 502, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }

  return new Response(JSON.stringify({ clientSecret: session.client_secret }), {
    status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': 'https://atlassports.ai' },
  });
}

export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    },
  });
}
