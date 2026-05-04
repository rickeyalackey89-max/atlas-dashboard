// checkout function v3 - always 200 to avoid CF 5xx interception
export async function onRequestPost(context) {
  var env = context.env;
  var headers = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': 'https://atlassports.ai' };

  if (!env.STRIPE_SECRET_KEY || !env.STRIPE_PRICE_ID) {
    return new Response(JSON.stringify({ error: 'Missing env vars' }), { status: 200, headers: headers });
  }

  var body = 'mode=subscription&ui_mode=embedded'
    + '&line_items[0][price]=' + env.STRIPE_PRICE_ID
    + '&line_items[0][quantity]=1'
    + '&return_url=https%3A%2F%2Fatlassports.ai%2Fdashboard%2Fwelcome%3Fsession_id%3D%7BCHECKOUT_SESSION_ID%7D';

  try {
    var resp = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + env.STRIPE_SECRET_KEY, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body,
    });
    var text = await resp.text();
    var session = {};
    try { session = JSON.parse(text); } catch(e) {
      return new Response(JSON.stringify({ error: 'Stripe non-JSON: ' + text.slice(0,100) }), { status: 200, headers: headers });
    }
    if (!resp.ok) {
      var msg = (session.error && session.error.message) ? session.error.message : ('Stripe error ' + resp.status);
      return new Response(JSON.stringify({ error: msg }), { status: 200, headers: headers });
    }
    if (!session.client_secret) {
      return new Response(JSON.stringify({ error: 'No client_secret returned' }), { status: 200, headers: headers });
    }
    return new Response(JSON.stringify({ clientSecret: session.client_secret }), { status: 200, headers: headers });
  } catch(e) {
    return new Response(JSON.stringify({ error: 'Exception: ' + (e && e.message ? e.message : String(e)) }), { status: 200, headers: headers });
  }
}

export async function onRequestOptions() {
  return new Response(null, { status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' } });
}