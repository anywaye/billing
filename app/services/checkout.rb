# The checkout namespace: what a subscriber does at the moment they start paying.
#
# There is no table here and deliberately no model of its own. A checkout session
# is a **value** — a subscriber, a plan, a quantity and an outcome — and the rows
# it touches belong to models that already exist: `Customer` owns the processor
# record, and `Subscription` is written by `Subscriptions::Lifecycle` and by
# nothing else (`AGENTS.md`, Subscriptions).
#
# ## Why there is no error class here
#
# `Subscriptions::Refused` exists because a **verified processor event** could not
# be applied to a row this service already had, and the transport — the webhook —
# has to record the reason on `processor_webhooks.error` and answer 200. A
# checkout is not that: it is a request, and its failure has no delivery row and
# no retry. So `Checkout::Session#complete` **returns an `Outcome`** in every
# case, and a refusal is one of the outcomes rather than an exception.
#
# That is the whole reason this file has no class in it, and it is a decision
# rather than an omission. The negative case of this packet is the one that
# matters — a declined checkout must leave the subscription untouched and be
# reported as a failure — and an exception is the easiest way to lose it, because
# "the caller forgot to rescue" and "the caller handled it" are indistinguishable
# from the return value. There is no path out of `complete` that is not an
# `Outcome`, so a failure cannot be half-handled.
module Checkout
end
