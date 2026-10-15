# REPORT — billing-live-stripe-01: the first charge against real Stripe

**Status: done, gated, recorded.** Five production-breaking defects found by
recording the real API, fixed, and re-proved live end to end.

## What this packet is

Everything before it proved billing against doubles. A double answers with
the shape its author imagined, so a client can drift from the API it claims
to speak and every test stays green. This packet put the real test-mode API
behind the client — VCR cassettes recorded against Stripe for the five
`Processor::StripeClient` requests — and then walked the whole loop against
the running service with `stripe listen` forwarding real webhook bytes.

## The five defects, and the evidence for each

1. **`create_checkout_session` sent no `success_url`.** Stripe requires it on
   a hosted Checkout Session; every real session was refused
   (`Missing required param: success_url`). The door that takes money could
   not open. Fixed: `success_url` is a required keyword and a required field
   on `POST /v1/subscriptions` (422 naming it when absent or relative), with
   `cancel_url` optional and defaulting to it. `openapi/v1.yaml` **2.5.0**.
2. **`apply_plan_change` sent `items: [price_id]` — a bare string list.**
   Stripe refuses it ("Invalid object"). Fixed: one request became two — a
   retrieve that names the item being moved by the PROCESSOR's own item id,
   then an update of that item.
3. **…and even the object form appends instead of replacing.** Measured: the
   fixture subscription came back holding BOTH prices after a naive move, so
   a plan change would have silently billed two plans. The item id is what
   makes it a move. (2 and 3 are one fix with two pieces of evidence.)
4. **`Stripe::Invoice.upcoming` no longer exists** in stripe 19.6 — Stripe
   replaced `/v1/invoices/upcoming` with `/v1/invoices/create_preview`. Every
   real preview raised `NoMethodError`. Fixed: `create_preview`.
5. **Live `invoice.paid` carries no `paid`, no `charge`, no
   `payment_intent`, and no top-level `subscription`** (API 2026-03-25).
   With the old normalizer: the charges recorder screened on `paid` = nil and
   **recorded no charge for any real payment**, and the payment event's
   subject fell back to the customer id. Fixed: `status == "paid"` is
   accepted beside `paid == true`; the subscription is read from
   `parent.subscription_details`; the charge id falls back to the invoice's
   own id. Both shapes are now pinned by
   `test/services/webhooks/live_invoice_shape_test.rb`, which ingests the
   committed old fixture AND a verbatim recording of the real payload.

## The live drill, as run (2026-10-15, test mode, account `acct_1TF2jdCm…`)

```
plan + customer seeded            -> plan=fd9b6864…, customer=a2173253…
POST session (fixed client)       -> cs_test_a16U1DzIHTKRkiRIGzRWGJGhw2All4B…,
                                     https://checkout.stripe.com/c/pay/…, 1900 USD
stripe subscriptions create (A)   -> billing.subscription.started subject=5e908d39…
                                     row status=active plan=live-drill
stripe subscriptions create (B)   -> charge recorded: in_1UQwuHCm…, 4900 USD,
                                     description "1 × Cafaye Pro (live-test) (at $49.00 / month)"
                                     payment.succeeded subject=sub_1UQwuHCm… (the subscription)
upcoming_invoice (fixed client)   -> usd, subtotal 4900, unit_amount_decimal 4900.0
cancel_subscription (fixed client)-> cancel_at_period_end=true, status still active
customer.subscription.updated     -> row cancel_at_period_end=true via the real webhook
```

Nine real deliveries were ingested; the terminal outcomes were
`ignored:unhandled_event_type` for the types this build deliberately does not
map (`invoice.created`, `invoice.finalized`, `charge.succeeded`, …) — the
recorded-and-terminal design working on real bytes.

## The hermetic half

`test/services/processor/stripe_client_live_test.rb` replays cassettes under
`test/cassettes/stripe/` — recorded once against the real API, then replayed
with `allow_http_connections_when_no_cassette = false` and no key in the
environment. Verified: **5 runs, 20 assertions, 0 failures, with
`STRIPE_API_KEY` unset**. The cassettes contain no key material (`grep
sk_test|sk_live` returns nothing; VCR filters by value).

## What is recorded rather than fixed

* **A charge that arrives before its subscription row has a null
  `subscription_id`** — measured in the drill: Stripe delivered
  `invoice.paid` before `customer.subscription.created`, so the recorder
  resolved the customer but not yet the row. The charge is honest (customer
  and account are on it); backfilling the link when the row lands is a later
  packet.
* **The `cancel_at_period_end` fixture subscription** left in the test
  account by an early recording run is inert; the recordings used dedicated
  subscriptions after that, which is what makes re-recording idempotent.
