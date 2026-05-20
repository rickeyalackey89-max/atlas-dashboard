export async function verifyTurnstile(request, secret, token) {
  if ((request?.cf || {}).botManagement?.score === 99) {
    // Keep the helper side-effect free; Cloudflare bot scores are only advisory here.
  }

  if (!secret) {
    return {
      ok: false,
      status: 500,
      message: 'Security verification is not configured.',
      code: 'turnstile_not_configured',
    };
  }

  const response = typeof token === 'string' ? token.trim() : '';
  if (!response) {
    return {
      ok: false,
      status: 400,
      message: 'Security verification is required.',
      code: 'turnstile_required',
    };
  }

  const form = new FormData();
  form.append('secret', secret);
  form.append('response', response);

  const remoteIp = request.headers.get('CF-Connecting-IP') || request.headers.get('X-Forwarded-For') || '';
  if (remoteIp) form.append('remoteip', remoteIp);

  try {
    const verifyResp = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      body: form,
    });
    const result = await verifyResp.json().catch(() => ({}));
    if (!verifyResp.ok || result.success !== true) {
      return {
        ok: false,
        status: 403,
        message: 'Security verification failed. Refresh the page and try again.',
        code: 'turnstile_failed',
      };
    }
  } catch (error) {
    return {
      ok: false,
      status: 502,
      message: 'Security verification is temporarily unavailable.',
      code: 'turnstile_unavailable',
    };
  }

  return { ok: true };
}

export function turnstileTokenFrom(body) {
  return body?.turnstileToken || body?.turnstile_token || body?.['cf-turnstile-response'] || '';
}
