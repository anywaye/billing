# REPORT — billing on the local whole stack (2026-10-16)

The brief: stop diagnosing the CI/publish blocker (another agent owns it) and
test billing locally with the whole cafaye stack. This is what the walk found
and what it cost.

## The harness

`kit/launch`'s overlay (identity + gateway + courier + parlor + mailpit, on
kit's cluster/bus/Redis/collector) is the whole stack, and it collides with the
already-running `cafaye` project on kit's base ports. The README's escape hatch
is the recipe: a scratch copy of `launch/` at `/tmp/launch` with

- `LAUNCH_STACK_NAME=kit-launch-billing`, moved service ports (15091–15094,
  15090 mailpit) and moved infra ports (15550 postgres, 15650 NATS, 15750 NATS
  monitor, 15850 Redis),
- `BILLING` added to the overlay (transcribed from `billing/docker-compose.yml`
  plus the four keys that file leaves to the operator: the two Stripe secrets,
  `NATS_URL`, and the identity issuer/audience),
- `BILLING_URL=http://host.docker.internal:3000` on parlor.

**billing itself runs from source on the host** (`DATABASE_URL` at the launch
cluster's 15550, `NATS_URL` at 15650, `BILLING_IDENTITY_ISSUER` at the
published identity), because its image cannot build — `bundle install` fails
with `The path /rails/vendor/cafaye does not exist` (the Dockerfile copies
`Gemfile`/`Gemfile.lock` and bundles before `COPY . .`; the path gem is not
there yet). That is the same failure as the publish pipeline, and it is the
other agent's subject: not touched here.

Walk: `POST /v1/subscriptions` against the real test-mode API, checkout
completed in a browser with 4242, webhooks forwarded by
`stripe listen --forward-to 127.0.0.1:3000/v1/webhooks/stripe`, then the money
reads. Auth for `/v1` is a minted RS256 token (identity's own JWKS, audience
`billing`, a real account uuid) — see "the one seam that still blocks" below.

## What the walk found, in the order it bit

1. **A real payment recorded nothing: no subscription row, no charge.**
   Three defects, all fixed (commit `e362ba0`):
   - the subscription insert was refused by `subscriptions_live_account_plan_idx`
     (the walk had a live fake-door subscription on the same plan) and
     `Webhooks::Ingestion` filed that refusal as `ignored:duplicate_delivery` —
     a real payment recorded as a non-event. Only a violation whose fact is
     already stored is a duplicate now; anything else parks as `failed:`.
   - the first checkout's `invoice.paid` arrives before
     `customer.subscription.created`, and nothing ever wrote
     `customers.processor_customer_id` from a webhook, so the charge resolved no
     customer and was skipped. The invoice's metadata carries the cafaye link;
     the normalizer reads it, the recorder consults it first, and the lifecycle
     backfills the processor id once (`Customer.updated`, one line). The same
     backfill is what makes `upcoming_invoice` and `payment_method` work for a
     `/v1`-created customer at all — both send the processor customer id.
   - `settled_or_due` read `paid` while the normalizer accepted
     `status: "paid"`, so one invoice could be paid for the event and unpaid for
     the amount.
2. **`NATS_URL` set crashed the boot**: the outbox relay logs `relay.url`,
   which does not exist, and the wiring test passed `logger: nil` — safe
   navigation skips the argument, so the suite never saw it. Committed with
   the same slice.
3. **The portal could never open** (`4ad01be`): `payment_method` demanded a
   relative `return_url` and Stripe refuses one (`InvalidRequestError: Not a
   valid URL`). The field is the checkout `success_url`'s rule now; parlor
   sends the absolute URL (`bdccc8f`, which also repoints two tenancy.yml
   declarations that had drifted 13 lines and been red since `3069dc8`).
4. **No span had ever left the process** (this commit): the OTLP default
   endpoint was the collector's base address, and the Ruby exporter uses a
   handed-in endpoint verbatim — so every export raised "HTTP request path is
   empty" inside `span.on_finish`, one error per request, in a container too.
   It is the traces resource URL now (`…/v1/traces`), the compose file agrees,
   and a test holds the shape the exporter needs. Proven by pointing it at a
   one-off listener: `POST /v1/traces` arrives.
5. **`host.docker.internal` was blocked by Rails' host authorization** before
   the app saw the request (`Blocked hosts: host.docker.internal:3000`), for
   the documented local shape of "billing on the host, parlor in the stack".
   Development-only allowlist line, with the measurement in the comment.

## What works end to end now

- Real checkout → `customer.subscription.created` **PROCESSED** (row
  `active`, `sub_1UQy7r…`), `invoice.paid` **PROCESSED** with the charge
  recorded **before** the subscription event (`in_1UQy7p…`, 4900 USD, the
  invoice id as the processor key, `subscription_id` null — the recorded gap).
- `customers.processor_customer_id` backfilled (`cus_VRrr…`), so
  `GET …/upcoming_invoice` returns Stripe's real preview (4900 USD) and
  `POST …/payment_method` returns a real portal URL.
- `POST …/cancel {at_period_end: true}` → Stripe `cancel_at_period_end: true`
  → `customer.subscription.updated` **PROCESSED** → row `cancel_at_period_end:
  t`.
- Outbox fully drained: 8 events, 0 unpublished; the `cafaye` JetStream stream
  holds them (subjects include `billing.>`).
- Every stack member ready: identity, gateway, courier, parlor, mailpit,
  billing; parlor's container reaches host-run billing
  (`host.docker.internal:3000/readyz` → 200) and parlor's sign-in works
  (owner credentials minted by `launch`).

## The one seam that still blocks, and it is a decision

**parlor → billing is a 401 by design mismatch.** Parlor forwards the browser's
identity session token (opaque, base64url, 43 chars); billing's verifier wants
an RS256 JWT with `aud: billing` and a singular `account_id`, and identity
mints `accounts` (an array) — the recorded cross-repo disagreement. Walked in
the browser: signed in at parlor, opened `/billing/plans`, and billing answered
`401 Unauthorized` (problem+json, `instance: /v1/plans`); the screen degrades
to "Billing could not be reached, so the plans could not be loaded." Nothing
is wrong with the plumbing — the probe request from parlor's container reaches
billing and gets a 200 on `/readyz` — the token dialects do not meet. That is
the recorded DECISION NEEDED and it is unchanged by this work; the walk's
contribution is the exact failure, in place, with both services live.

### What the fake-door gap became

The fake door's subscriptions could not be managed: the row-addressed actions
dialled Stripe whatever processor owned the row, so a `sub_FAKE…` subscription
answered "has no upcoming invoice at the payment processor" for a projection
the fake could have given. Fixed in the same round: the projection now comes
from the fake's own ledger — the method that existed for exactly this ("the
controller's builder is one code path for both") and had no caller — and
cancel/change/portal are refused BY NAME on a fake row, saying which processor
holds it, because a pretend-Stripe is the failure `FakeClient`'s own class
comment forbids.
- Courier has no `billing.*` consumers (its four are `identity.*`), so billing's
  events land in the stream and nobody acts on them — the recorded
  receipt/welcome gap, unchanged.
- A host-run billing defaults its OTLP endpoint to the container's collector
  name, which does not resolve on the host, and kit publishes no collector port
  by design. Set `BILLING_OTEL_ENDPOINT` to a reachable traces URL when running
  from source, or run billing in the stack once its image builds.
- Test-mode artifacts accumulate in the Stripe account (customers,
  subscriptions, one invoiced checkout per walk), and the walk created a second
  Stripe customer for the same cafaye customer before the backfill landed
  (each checkout creates one when `processor_customer_id` is absent — now it
  will be present after the first subscription event).

## The follow-up round (the same day)

The user's "fix those issues" round landed three of the reported items:
identity's `POST /v1/session/tokens` — the exchange that closes the 401, in
which the account is named by a party allowed to name it, membership is checked
before signing, one account goes into the token and nothing anywhere picks
`accounts[0]` — parlor's BFF sending the minted bearer for billing calls (its
own test pinned the broken forwarding), and courier's
`Courier.Consumers.PaymentSucceeded`: the receipt the money event was waiting
for since billing-event-payloads-01. The telemetry endpoint and the blocked
host were fixed in the first round; the fake-door management warts are above.
The image build — the publish blocker — was fixed by another agent in the same
window.

## Numbers

billing: 1232 runs, 4028 assertions, 0 failures; rubocop clean on every
changed file. parlor: 52 files, 1130 tests, 50 checks, 0 failures. Commits:
`e362ba0`, `4ad01be`, this one — pushed to `master`; parlor `bdccc8f` pushed.
