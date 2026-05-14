// checkout function v5 - 3-day trial + promo codes + Ambassador attribution
// always 200 to avoid CF 5xx interception
export async function onRequestPost(context) {
  var env = context.env;
  var request = context.request;
  var headers = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': 'https://atlassports.ai' };

  if (!env.STRIPE_SECRET_KEY || !env.STRIPE_PRICE_ID) {
    return new Response(JSON.stringify({ error: 'Missing env vars' }), { status: 200, headers: headers });
  }

  // Optional inputs from client:
  // { ref: 'streamerName', promo: 'CODE', promo_attribution: 'CODE', ambassador_code: 'CODE', checkout_mode: 'hosted'|'embedded' }
  // - `promo` = customer typed code AND wants discount auto-applied (used for annual upsell URLs)
  // - `promo_attribution` = customer typed code but proceeding with monthly (no discount, just credit streamer)
  // - `ambassador_code` = canonical referral/ambassador attribution code
  var ref = '';
  var promo = '';
  var promoAttribution = '';
  var ambassadorCode = '';
  var checkoutMode = 'embedded';
  try {
    var payload = await request.json();
    if (payload && typeof payload.ref === 'string') ref = payload.ref.slice(0, 64).replace(/[^A-Za-z0-9_-]/g, '');
    if (payload && typeof payload.promo === 'string') promo = payload.promo.slice(0, 32).replace(/[^A-Za-z0-9_-]/g, '').toUpperCase();
    if (payload && typeof payload.promo_attribution === 'string') promoAttribution = payload.promo_attribution.slice(0, 32).replace(/[^A-Za-z0-9_-]/g, '').toUpperCase();
    if (payload && typeof payload.ambassador_code === 'string') ambassadorCode = payload.ambassador_code.slice(0, 32).replace(/[^A-Za-z0-9_-]/g, '').toUpperCase();
    if (payload && payload.checkout_mode === 'hosted') checkoutMode = 'hosted';
  } catch (e) { /* no body or invalid JSON - fine */ }

  var attributionCode = ambassadorCode || promoAttribution || promo || ref;
  attributionCode = attributionCode ? attributionCode.slice(0, 32).replace(/[^A-Za-z0-9_-]/g, '').toUpperCase() : '';

  var parts = [
    'mode=subscription',
    'line_items[0][price]=' + encodeURIComponent(env.STRIPE_PRICE_ID),
    'line_items[0][quantity]=1',
    // 3-day free trial on the subscription
    'subscription_data[trial_period_days]=3',
    // require a payment method even during trial (so renewal is automatic)
    'subscription_data[trial_settings][end_behavior][missing_payment_method]=cancel',
    // allow user to type a promo code in Stripe's UI
    'allow_promotion_codes=true'
  ];

  if (checkoutMode === 'hosted') {
    parts.push('success_url=' + encodeURIComponent('https://atlassports.ai/dashboard/welcome?session_id={CHECKOUT_SESSION_ID}'));
    parts.push('cancel_url=' + encodeURIComponent('https://atlassports.ai/checkout/?checkout_cancelled=1'));
  } else {
    // Stripe API 2026-04-22+ renamed the embedded Checkout UI mode to embedded_page.
    parts.push('ui_mode=embedded_page');
    parts.push('return_url=' + encodeURIComponent('https://atlassports.ai/dashboard/welcome?session_id={CHECKOUT_SESSION_ID}'));
  }

  // Affiliate tracking metadata (visible in Stripe Dashboard on both Session and Subscription)
  if (ref) {
    parts.push('metadata[ref]=' + encodeURIComponent(ref));
    parts.push('subscription_data[metadata][ref]=' + encodeURIComponent(ref));
  }

  // Canonical Ambassador attribution. The private Ambassador backend reads this
  // first, while still supporting legacy promo_code/streamer metadata.
  if (attributionCode) {
    parts.push('client_reference_id=' + encodeURIComponent(attributionCode));
    parts.push('metadata[ambassador_code]=' + encodeURIComponent(attributionCode));
    parts.push('metadata[referral_code]=' + encodeURIComponent(attributionCode));
    parts.push('subscription_data[metadata][ambassador_code]=' + encodeURIComponent(attributionCode));
    parts.push('subscription_data[metadata][referral_code]=' + encodeURIComponent(attributionCode));
  }

  // Streamer attribution: when user typed a promo code into our box but is proceeding
  // with monthly checkout (no discount), still credit the streamer who referred them.
  // Maps customer-facing code -> streamer slug for easy filtering in Stripe dashboard.
  if (promoAttribution) {
    var streamerMap = { '314MELL': '314MELL', 'KENFRMTHEMIT': 'kenfrmthemit' };
    var streamerSlug = streamerMap[promoAttribution] || promoAttribution;
    parts.push('metadata[promo_code]=' + encodeURIComponent(promoAttribution));
    parts.push('metadata[streamer]=' + encodeURIComponent(streamerSlug));
    parts.push('subscription_data[metadata][promo_code]=' + encodeURIComponent(promoAttribution));
    parts.push('subscription_data[metadata][streamer]=' + encodeURIComponent(streamerSlug));
  }

  // Auto-apply a promotion code if passed via URL (?promo=KYLE10)
  // Requires looking up the promotion_code object by `code` field.
  if (promo) {
    try {
      var lookupResp = await fetch('https://api.stripe.com/v1/promotion_codes?code=' + encodeURIComponent(promo) + '&active=true&limit=1', {
        headers: { 'Authorization': 'Bearer ' + env.STRIPE_SECRET_KEY }
      });
      var lookupJson = await lookupResp.json();
      if (lookupJson && lookupJson.data && lookupJson.data.length > 0) {
        parts.push('discounts[0][promotion_code]=' + encodeURIComponent(lookupJson.data[0].id));
        // can't combine allow_promotion_codes with discounts; drop the allow flag
        parts = parts.filter(function(p){ return p !== 'allow_promotion_codes=true'; });
        parts.push('metadata[promo_applied]=' + encodeURIComponent(promo));
        parts.push('subscription_data[metadata][promo_applied]=' + encodeURIComponent(promo));
      }
    } catch (e) { /* lookup failed - fall through with allow_promotion_codes still on */ }
  }

  var body = parts.join('&');

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
    if (checkoutMode === 'hosted') {
      if (!session.url) {
        return new Response(JSON.stringify({ error: 'No hosted checkout URL returned' }), { status: 200, headers: headers });
      }
      return new Response(JSON.stringify({ url: session.url }), { status: 200, headers: headers });
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
