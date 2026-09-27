// Transactional email Worker for Atoll (docs/accounts.md, "Email delivery").
// Owns the sender address and provider; Atoll only supplies to/subject/text.
const encoder = new TextEncoder();

async function authorized(request, env) {
  const header = request.headers.get('authorization') || '';
  if (!env.TOKEN || !header.startsWith('Bearer ')) return false;
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', encoder.encode(header.slice(7))),
    crypto.subtle.digest('SHA-256', encoder.encode(env.TOKEN)),
  ]);
  const left = new Uint8Array(a);
  const right = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

function valid(body) {
  return (
    body &&
    typeof body.to === 'string' &&
    body.to.length <= 320 &&
    /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(body.to) &&
    typeof body.subject === 'string' &&
    body.subject.length >= 1 &&
    body.subject.length <= 998 &&
    !/[\r\n]/.test(body.subject) &&
    typeof body.text === 'string' &&
    body.text.length >= 1 &&
    body.text.length <= 100000
  );
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return new Response('', { status: 405 });
    if (!(await authorized(request, env))) return new Response('', { status: 401 });

    let body;
    try {
      body = await request.json();
    } catch {
      return new Response('', { status: 400 });
    }
    if (!valid(body)) return new Response('', { status: 400 });

    const key = request.headers.get('idempotency-key');
    if (key && key.length <= 256) {
      if (await env.IDEMPOTENCY.get(key)) return new Response('', { status: 200 });
    }

    try {
      await env.EMAIL.send({
        from: { email: env.SENDER, name: env.SENDER_NAME || env.SENDER },
        to: body.to,
        subject: body.subject,
        text: body.text,
      });
    } catch (error) {
      const status = error && error.code === 'E_RATE_LIMIT_EXCEEDED' ? 429 : 502;
      return new Response('', { status });
    }

    if (key && key.length <= 256) {
      await env.IDEMPOTENCY.put(key, '1', { expirationTtl: 86400 });
    }
    return new Response('', { status: 202 });
  },
};
