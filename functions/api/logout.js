export async function onRequestGet() {
  return logoutResponse();
}

export async function onRequestPost() {
  return logoutResponse();
}

function logoutResponse() {
  const headers = new Headers({
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
  });
  [
    'atlas_premium_token=; Path=/; Max-Age=0; SameSite=Lax; Secure; HttpOnly',
    'atlas_premium_client_token=; Path=/; Max-Age=0; SameSite=Lax; Secure',
    'atlas_premium_token=; Path=/; Max-Age=0; Domain=atlassports.ai; SameSite=Lax; Secure; HttpOnly',
    'atlas_premium_client_token=; Path=/; Max-Age=0; Domain=atlassports.ai; SameSite=Lax; Secure',
  ].forEach((cookie) => headers.append('Set-Cookie', cookie));
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers,
  });
}
