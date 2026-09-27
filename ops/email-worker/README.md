# Atoll email Worker

Implements the Worker contract in `docs/accounts.md` ("Email delivery") on
Cloudflare Email Service: authenticated POST of `{to, subject, text}` with an
`Idempotency-Key`, deduplicated in KV for 24 hours, sent through the
`send_email` binding. The Worker owns the sender address; Atoll never sees
provider credentials. Responses follow the contract: 202 accepted, 200 for a
replayed idempotency key, 401/400 rejected, 429/502 retryable.

Deploy (once per environment, from this directory):

```sh
npx wrangler email sending enable <your-domain>   # onboard the sender domain
npx wrangler kv namespace create IDEMPOTENCY      # put the id in wrangler.jsonc
# set SENDER / SENDER_NAME in wrangler.jsonc vars
npx wrangler deploy
openssl rand -base64 32 | npx wrangler secret put TOKEN
```

Then configure Atoll with the deployed URL and the same token:

```sh
ATOLL_EMAIL_WORKER_URL=https://atoll-email.<account>.workers.dev
ATOLL_EMAIL_WORKER_TOKEN=<the TOKEN secret>
```

Verify end to end with a real inbox you control:

```sh
curl -si "$ATOLL_EMAIL_WORKER_URL" \
  -H "authorization: Bearer $ATOLL_EMAIL_WORKER_TOKEN" \
  -H "idempotency-key: deploy-test-$(date +%s)" \
  -H "content-type: application/json" \
  -d '{"to":"you@example.com","subject":"Atoll email test","text":"It works."}'
```

Email Service is transactional-only; complete the domain's DKIM/SPF records as
the onboarding flow instructs before relying on deliverability.
