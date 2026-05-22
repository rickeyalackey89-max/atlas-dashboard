const ALLOWED_ORIGIN = 'https://atlassports.ai';
const MAX_BODY_BYTES = 256 * 1024;
const AUDIT_TTL_SECONDS = 60 * 60 * 24 * 45;
const ISSUE_TTL_SECONDS = 60 * 60 * 24 * 180;

export async function onRequestPost(context) {
  const { request, env } = context;
  const headers = apiHeaders();
  const auth = await verifyAuditToken(request, env);
  if (!auth.ok) {
    await logAuditEvent(context, request, 'audit_ingest_auth_failed', { reason: auth.reason });
    return json({ ok: false, error: 'Unauthorized.' }, 401, headers);
  }

  const length = Number(request.headers.get('Content-Length') || 0);
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    return json({ ok: false, error: 'Audit payload too large.' }, 413, headers);
  }

  let report;
  try {
    report = await request.json();
  } catch {
    return json({ ok: false, error: 'Invalid JSON.' }, 400, headers);
  }

  const normalized = normalizeAuditReport(report);
  const deterministic = analyzeAuditReport(normalized);
  const aiReview = await reviewWithOpenAI(env, normalized, deterministic);
  const issue = buildIssue(normalized, deterministic, aiReview);
  const stored = await storeAudit(context, normalized, deterministic, aiReview, issue);

  if (issue.required) {
    context.waitUntil(createGitHubIssueIfConfigured(env, issue, stored.key));
  }

  await logAuditEvent(context, request, 'audit_ingest_served', {
    run_id: normalized.run_id,
    run_type: normalized.run_type,
    window: normalized.window,
    sports: normalized.sports,
    severity: deterministic.severity,
    issue_required: issue.required,
  });

  return json({
    ok: true,
    audit_key: stored.key,
    severity: deterministic.severity,
    issue_required: issue.required,
    title: issue.title,
    summary: issue.summary,
  }, 200, headers);
}

export async function onRequestGet(context) {
  const { request, env } = context;
  const headers = apiHeaders();
  const auth = await verifyAuditToken(request, env);
  if (!auth.ok) {
    return json({ ok: false, error: 'Unauthorized.' }, 401, headers);
  }

  const kv = env.ATLAS_SECURITY_KV;
  if (!kv || typeof kv.get !== 'function') {
    return json({ ok: false, error: 'Audit storage unavailable.' }, 503, headers);
  }

  const raw = await kv.get('audit-runs:latest');
  if (!raw) return json({ ok: false, error: 'No audit reports stored yet.' }, 404, headers);

  try {
    return json({ ok: true, latest: JSON.parse(raw) }, 200, headers);
  } catch {
    return json({ ok: false, error: 'Stored audit report is unreadable.' }, 502, headers);
  }
}

export async function onRequestOptions() {
  return new Response(null, { status: 204, headers: apiHeaders() });
}

function apiHeaders(extra) {
  return {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Atlas-Audit-Token',
    'Cache-Control': 'private, no-store, max-age=0',
    'X-Robots-Tag': 'noindex, nofollow, noai, noimageai',
    ...(extra || {}),
  };
}

function json(body, status, headers) {
  return new Response(JSON.stringify(body), { status, headers });
}

async function verifyAuditToken(request, env) {
  const expected = String(env.ATLAS_AUDIT_INGEST_TOKEN || '').trim();
  if (!expected) return { ok: false, reason: 'missing_server_token' };
  const supplied = getAuditToken(request);
  if (!supplied) return { ok: false, reason: 'missing_token' };
  const ok = await safeCompare(supplied, expected);
  return ok ? { ok: true } : { ok: false, reason: 'bad_token' };
}

function getAuditToken(request) {
  const direct = String(request.headers.get('X-Atlas-Audit-Token') || '').trim();
  if (direct) return direct;
  const auth = String(request.headers.get('Authorization') || '');
  return /^Bearer\s+/i.test(auth) ? auth.replace(/^Bearer\s+/i, '').trim() : '';
}

function normalizeAuditReport(report) {
  const now = new Date().toISOString();
  const sports = Array.isArray(report.sports)
    ? report.sports.map((s) => String(s || '').trim().toUpperCase()).filter(Boolean)
    : [];
  const failures = Array.isArray(report.failures) ? report.failures.map(String).filter(Boolean) : [];
  const artifacts = Array.isArray(report.artifacts) ? report.artifacts.map(normalizeArtifact) : [];
  const steps = Array.isArray(report.steps) ? report.steps.map(normalizeStep) : [];
  const logTail = Array.isArray(report.log_tail) ? report.log_tail.map(String).slice(-160) : [];

  return {
    run_id: String(report.run_id || crypto.randomUUID()),
    run_type: String(report.run_type || 'unknown').toLowerCase(),
    window: String(report.window || report.window_label || 'manual'),
    status: String(report.status || '').toLowerCase(),
    exit_code: Number.isFinite(Number(report.exit_code)) ? Number(report.exit_code) : 0,
    sports,
    started_at: String(report.started_at || ''),
    finished_at: String(report.finished_at || now),
    host: String(report.host || ''),
    log_path: String(report.log_path || ''),
    failures,
    artifacts,
    steps,
    log_tail: logTail,
    source: {
      publisher_version: String(report.publisher_version || 'unknown'),
      root: String(report.root || ''),
    },
  };
}

function normalizeArtifact(item) {
  const fields = item && typeof item === 'object' ? item : {};
  return {
    sport: String(fields.sport || '').toUpperCase(),
    name: String(fields.name || ''),
    path: String(fields.path || ''),
    exists: Boolean(fields.exists),
    verdict: String(fields.verdict || fields.status || '').toUpperCase(),
    rows: numberOrNull(fields.rows),
    run_id: stringOrNull(fields.run_id),
    generated_at: stringOrNull(fields.generated_at),
    summary: fields.summary && typeof fields.summary === 'object' ? fields.summary : {},
  };
}

function normalizeStep(item) {
  const fields = item && typeof item === 'object' ? item : {};
  return {
    name: String(fields.name || fields.stage || ''),
    status: String(fields.status || '').toUpperCase(),
    exit_code: numberOrNull(fields.exit_code),
    message: String(fields.message || ''),
  };
}

function analyzeAuditReport(report) {
  const failures = [];
  const warnings = [];

  if (report.exit_code !== 0) failures.push(`Scheduled task exited with code ${report.exit_code}.`);
  if (report.failures.length) failures.push(...report.failures);
  if (report.status && !['ok', 'pass', 'success', 'completed', 'complete'].includes(report.status)) {
    failures.push(`Run status is ${report.status}.`);
  }

  for (const artifact of report.artifacts) {
    if (!artifact.exists) failures.push(`Missing artifact: ${artifact.sport || 'GLOBAL'} ${artifact.name}`);
    if (artifact.verdict === 'FAIL' || artifact.verdict === 'ERROR') {
      failures.push(`Artifact failed: ${artifact.sport || 'GLOBAL'} ${artifact.name}`);
    } else if (artifact.verdict === 'WARN' || artifact.verdict === 'DEGRADED') {
      warnings.push(`Artifact warning: ${artifact.sport || 'GLOBAL'} ${artifact.name}`);
    }
  }

  for (const step of report.steps) {
    if (step.status === 'FAIL' || step.status === 'ERROR' || (step.exit_code !== null && step.exit_code !== 0)) {
      failures.push(`Step failed: ${step.name || 'unknown'} ${step.message}`.trim());
    } else if (step.status === 'WARN') {
      warnings.push(`Step warning: ${step.name || 'unknown'} ${step.message}`.trim());
    }
  }

  const severity = failures.length ? 'critical' : warnings.length ? 'warning' : 'ok';
  return {
    severity,
    issue_required: failures.length > 0,
    failures: uniqueStrings(failures).slice(0, 20),
    warnings: uniqueStrings(warnings).slice(0, 20),
  };
}

async function reviewWithOpenAI(env, report, deterministic) {
  const apiKey = String(env.OPENAI_API_KEY || '').trim();
  if (!apiKey) {
    return { ok: false, skipped: true, reason: 'missing_openai_key' };
  }

  const model = String(env.ATLAS_AUDIT_OPENAI_MODEL || 'gpt-4.1-mini').trim();
  const payload = {
    model,
    temperature: 0.1,
    max_output_tokens: 650,
    input: [
      {
        role: 'system',
        content: 'You are Atlas scheduled-run audit triage. Return compact JSON only. Be strict about failed evals, missing artifacts, stale publishes, and failed source contracts.',
      },
      {
        role: 'user',
        content: JSON.stringify({
          instruction: 'Summarize this scheduled-run audit. If any deterministic failure exists, set issue_required true and provide a concise issue title and action list.',
          deterministic,
          report: compactReport(report),
          output_schema: {
            severity: 'ok|warning|critical',
            issue_required: true,
            title: 'short issue title',
            summary: 'what happened',
            root_cause_hypothesis: 'likely cause or unknown',
            next_actions: ['action 1', 'action 2'],
            needs_human: true,
          },
        }),
      },
    ],
  };

  let resp;
  try {
    resp = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });
  } catch (err) {
    return { ok: false, error: `openai_fetch_failed:${String(err && err.message ? err.message : err)}` };
  }

  if (!resp.ok) {
    return { ok: false, error: `openai_status_${resp.status}` };
  }

  const data = await resp.json();
  const text = extractResponseText(data);
  const parsed = parseJsonObject(text);
  return parsed ? { ok: true, parsed } : { ok: true, text: text.slice(0, 2000) };
}

function compactReport(report) {
  return {
    run_id: report.run_id,
    run_type: report.run_type,
    window: report.window,
    sports: report.sports,
    exit_code: report.exit_code,
    failures: report.failures.slice(0, 10),
    artifacts: report.artifacts.map((a) => ({
      sport: a.sport,
      name: a.name,
      exists: a.exists,
      verdict: a.verdict,
      rows: a.rows,
      run_id: a.run_id,
      generated_at: a.generated_at,
      summary: a.summary,
    })).slice(0, 30),
    steps: report.steps.slice(0, 30),
    log_tail: report.log_tail.slice(-80),
  };
}

function buildIssue(report, deterministic, aiReview) {
  const parsed = aiReview && aiReview.parsed ? aiReview.parsed : {};
  const required = Boolean(deterministic.issue_required || parsed.issue_required);
  const severity = String(parsed.severity || deterministic.severity || 'warning').toLowerCase();
  const title = String(parsed.title || `Atlas ${report.run_type} audit ${severity}: ${report.window}`).slice(0, 160);
  const nextActions = Array.isArray(parsed.next_actions) ? parsed.next_actions.map(String).slice(0, 8) : [];
  return {
    required,
    severity,
    title,
    summary: String(parsed.summary || deterministic.failures[0] || deterministic.warnings[0] || 'Audit completed cleanly.'),
    root_cause_hypothesis: String(parsed.root_cause_hypothesis || ''),
    next_actions: nextActions,
    needs_human: Boolean(required || parsed.needs_human),
    run_id: report.run_id,
    run_type: report.run_type,
    window: report.window,
    sports: report.sports,
    failures: deterministic.failures,
    warnings: deterministic.warnings,
    audit_log_path: report.log_path,
  };
}

async function storeAudit(context, report, deterministic, aiReview, issue) {
  const kv = context.env.ATLAS_SECURITY_KV;
  const stored = {
    report,
    deterministic,
    ai_review: aiReview,
    issue,
    stored_at: new Date().toISOString(),
  };
  const key = `audit-runs:${Date.now()}:${report.run_id}`;
  if (!kv || typeof kv.put !== 'function') {
    console.log(JSON.stringify({ event: 'audit_run', key, stored }));
    return { key };
  }
  await kv.put(key, JSON.stringify(stored), { expirationTtl: AUDIT_TTL_SECONDS });
  await kv.put('audit-runs:latest', JSON.stringify(stored), { expirationTtl: AUDIT_TTL_SECONDS });
  if (issue.required) {
    await kv.put(`audit-runs:issue:${Date.now()}:${report.run_id}`, JSON.stringify(issue), {
      expirationTtl: ISSUE_TTL_SECONDS,
    });
  }
  return { key };
}

async function createGitHubIssueIfConfigured(env, issue, auditKey) {
  const token = String(env.GITHUB_TOKEN || '').trim();
  const repo = String(env.ATLAS_AUDIT_GITHUB_REPO || '').trim();
  if (!token || !repo || !repo.includes('/')) return;

  const body = [
    issue.summary,
    '',
    `Run: ${issue.run_id}`,
    `Type: ${issue.run_type}`,
    `Window: ${issue.window}`,
    `Sports: ${issue.sports.join(', ') || 'unknown'}`,
    `Audit key: ${auditKey}`,
    '',
    'Failures:',
    ...(issue.failures.length ? issue.failures.map((x) => `- ${x}`) : ['- None']),
    '',
    'Warnings:',
    ...(issue.warnings.length ? issue.warnings.map((x) => `- ${x}`) : ['- None']),
    '',
    'Next actions:',
    ...(issue.next_actions.length ? issue.next_actions.map((x) => `- ${x}`) : ['- Review scheduled audit artifacts.']),
  ].join('\n');

  await fetch(`https://api.github.com/repos/${repo}/issues`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'atlas-audit-worker',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      title: issue.title,
      body,
      labels: ['atlas-audit', issue.severity],
    }),
  });
}

async function logAuditEvent(context, request, event, details) {
  const kv = context.env.ATLAS_SECURITY_KV;
  const record = {
    event,
    at: new Date().toISOString(),
    path: new URL(request.url).pathname,
    ip: request.headers.get('CF-Connecting-IP') || '',
    user_agent: request.headers.get('User-Agent') || '',
    details: details || {},
  };
  if (!kv || typeof kv.put !== 'function') {
    console.log(JSON.stringify(record));
    return;
  }
  await kv.put(`audit-runs:events:${record.at.slice(0, 10)}:${Date.now()}:${crypto.randomUUID()}`, JSON.stringify(record), {
    expirationTtl: AUDIT_TTL_SECONDS,
  });
}

function extractResponseText(data) {
  if (typeof data.output_text === 'string') return data.output_text;
  const chunks = [];
  for (const item of Array.isArray(data.output) ? data.output : []) {
    for (const content of Array.isArray(item.content) ? item.content : []) {
      if (typeof content.text === 'string') chunks.push(content.text);
    }
  }
  return chunks.join('\n').trim();
}

function parseJsonObject(text) {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    const match = text.match(/\{[\s\S]*\}/);
    if (!match) return null;
    try { return JSON.parse(match[0]); } catch { return null; }
  }
}

function numberOrNull(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function stringOrNull(value) {
  return value === null || value === undefined || value === '' ? null : String(value);
}

function uniqueStrings(items) {
  const seen = new Set();
  const out = [];
  for (const item of items) {
    const value = String(item || '').trim();
    if (!value || seen.has(value)) continue;
    seen.add(value);
    out.push(value);
  }
  return out;
}

async function safeCompare(a, b) {
  const left = String(a || '');
  const right = String(b || '');
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return diff === 0;
}
