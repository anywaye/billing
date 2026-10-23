require "test_helper"

# Cross-account isolation, behaviourally, against Postgres.
#
# ## The property every test here asserts
#
# > **An account A operation reaches nothing belonging to account B, and gets the
# > same answer as it would for something that does not exist.**
#
# ## Why these live here and not on the HTTP surface
#
# Because `/v1` has no caller to be account A. There is no token, so there is no
# account to compare against, and a wire-level "account A asks for account B's
# resource" cannot be written — there is no A to send. That gap is the recorded
# one in `contract/tenant_isolation_matrix_test.rb` and in each controller's own
# header, and nothing here pretends to close it or to paper over it.
#
# What *is* available is better than a wire test, because it is closer to the
# money: the account boundary in this service is **a fact in the data**, carried
# by `Subscription#account_id` and `Customer#owner_id`, and it is enforced in
# three places. All three are exercised below with two real accounts, and the
# fourth operation kind — delete — is asserted to have nothing to act on.
#
# This is the same split darkroom-09 used, and for the same reason: *is the
# scoping still written down* is a property of the source and *does the scoping
# actually hold* is a property of Postgres. Neither substitutes for the other,
# which is why there is a structural file beside this one.
#
# ## Two things that make a test here useless, and are therefore avoided
#
#   * **Asserting only that a lookup returned nil.** A cross-tenant write that
#     missed its scoping and then lost a second race on some other constraint
#     also returns nothing. So every cross-account assertion here says what
#     *survived*, not only what was refused.
#   * **Printing the other account's row.** A failure that dumps account B's
#     price and status into CI output is a leak the spec created. Every
#     comparison goes through `TwoAccounts#fingerprint`, a digest, so a failure
#     names *which* ids moved and nothing about what they held.
class TenantCrossAccountDeliveryTest < ActiveSupport::TestCase
  # The four operation kinds, plus `delete`. Repeated from
  # `TenantAccountEntryPointMatrixTest::KINDS` rather than referenced, because a
  # test file that names another test file's constant cannot be run on its own —
  # and `bin/rails test test/tenant/cross_account_delivery_test.rb` is a command
  # AGENTS.md documents. Five words duplicated is a smaller cost than a spec that
  # only runs in the full suite, and this file asserts the vocabulary is exactly
  # these five so the two lists cannot grow apart unnoticed.
  OPERATION_KINDS = %w[read list write update delete].freeze

  class << self
    # The test methods this file defines, read at **run** time.
    #
    # `public_instance_methods(false)` rather than `instance_methods`, so the
    # handful of helpers `ActiveSupport::TestCase` contributes are not counted as
    # negative tests. And at run time rather than at load time, because the `test`
    # macro defines each method as the class body is evaluated — a count taken
    # while the body is still executing would see only the tests above it.
    def declared_test_methods
      public_instance_methods(false).grep(/\Atest_/).sort
    end

    # The tests that are **about** cross-account isolation, as opposed to the
    # ones that count the file. The `meta:` prefix is the discriminator, and it
    # has to be explicit: the four bookkeeping tests are not negative tests, and a
    # count that included them would report a coverage number the tests do not
    # support.
    def negative_test_methods
      declared_test_methods.reject { |method| method.to_s.start_with?("test_meta:") }
    end

    def bookkeeping_test_methods
      declared_test_methods.select { |method| method.to_s.start_with?("test_meta:") }
    end

    # The operation each negative test covers, from its own name.
    #
    # **No space after the colon**, because the `test` macro mangles the name it
    # is given: `"read: an account cannot…"` becomes `test_read:_an_account_cannot…`.
    # A regexp written against the source string rather than the method name
    # matches nothing and the breakdown reports zero of everything, which reads
    # as "this file has no negative tests" rather than as a broken predicate.
    def negative_test_kinds
      negative_test_methods.filter_map { |method| method.to_s[/\Atest_([a-z_]+):/, 1] }
    end
  end

  setup do
    travel_to(frozen_now)
  end

  # --- the boundaries that hold ---------------------------------------------

  # **read.** The one account-scoped index on `customers` is over
  # `(owner_type, owner_id, processor)`: one customer per account per processor.
  # Account B cannot acquire a row that answers to account A's owner, which means
  # a lookup keyed on the owner cannot return two accounts' rows.
  test "read: one account cannot acquire another account's customer row" do
    create_account_customers

    duplicate = Customer.new(
      owner_type: "Account", owner_id: ACCOUNT_B, processor: "stripe",
      processor_customer_id: "cus_FAKEthirdpartyCCCCCCCCCCCC"
    )

    assert_not duplicate.valid?
    # On `:processor`, not `:owner_id`. The rule is one customer per
    # `(owner_type, owner_id, processor)` and `Customer` expresses it as
    # `validates :processor, uniqueness: { scope: %i[owner_type owner_id] }`, so
    # Active Record reports the failure against the attribute that is *not* in the
    # scope. Asserting on `:owner_id` would be wrong today and would go on
    # passing the moment somebody rewrote the validation to the other spelling.
    assert_includes duplicate.errors[:processor], "has already been taken"
    assert_equal 2, Customer.where(owner_type: "Account").count,
      "the pair must be two rows, or the comparison above proves nothing"
  end

  # **read.** The live-uniqueness index is over `(account_id, plan_id)`, and it
  # is scoped to an account: two accounts may each hold a live subscription on
  # the *same* plan, which is the case a fixture with a plan per account could
  # not distinguish from a correct index.
  test "read: two accounts may hold live subscriptions on the same plan" do
    create_account_subscriptions

    assert_equal [ shared_plan.id ], subscription_a.plan_id == shared_plan.id ? [ subscription_a.plan_id ] : []
    assert_equal shared_plan.id, subscription_b.plan_id
    assert_equal 2, Subscription.live.count,
      "two accounts on one plan is the legitimate case the index must not refuse"
  end

  # **update.** The common shape this whole packet is about: a service that scopes
  # its reads and forgets its writes. A cross-account *write* is data loss rather
  # than disclosure, and no read-path assertion in the repository would notice.
  #
  # `RecordNotUnique` and not a validation failure, because the index is what
  # refuses it — the model has no uniqueness validation on this pair, by design,
  # since the index's predicate is a statement about live statuses that a
  # validation cannot express.
  test "update: an account cannot hold two live subscriptions on one plan" do
    create_account_subscriptions

    second = Subscription.new(
      account_id: ACCOUNT_A, customer: customer_a, plan: shared_plan,
      processor_subscription_id: "sub_FAKEsameplananewAAAAAAA", status: "active"
    )

    assert_raises(ActiveRecord::RecordNotUnique) { second.save! }
    assert_equal 2, Subscription.live.count, "the refused write must not have left a row"
  end

  # The other half of the same index: `canceled` is the only terminal status, so
  # an account that cancels and comes back has to be able to resubscribe to the
  # same plan. Without this the index would be correct and the product wrong, and
  # the difference is one status — which is why the predicate is asserted here
  # rather than left to the index's text.
  test "update: the account boundary is scoped to live rows, so a cancelled account may return" do
    create_account_subscriptions
    subscription_a.update!(status: "canceled")

    returning = Subscription.new(
      account_id: ACCOUNT_A, customer: customer_a, plan: shared_plan,
      processor_subscription_id: "sub_FAKEReturningAAAAAAA", status: "active"
    )

    assert returning.save, "a cancelled subscription must not block the account from resubscribing: #{returning.errors.full_messages.inspect}"
  end

  # **update.** The model guard, and the one place in this service where an
  # account is compared against another account at all.
  # `Subscription#account_is_the_customers_owner` says a subscription's
  # `account_id` is the customer's own account and cannot drift from it. That is
  # the cross-tenant write guard: there is no other code path in `app/` that
  # stops a subscription being written against somebody else's account.
  test "update: a subscription cannot be written against an account that is not its customer's" do
    create_account_customers
    plan = shared_plan

    # Account A's customer, billed to account B. This is the shape of the defect
    # the whole packet hunts: one account's row pointed at another's money.
    mismatched = Subscription.new(
      account_id: ACCOUNT_B, customer: customer_a, plan: plan,
      processor_subscription_id: "sub_FAKEmismatchedAAAAAAA", status: "active"
    )

    assert_not mismatched.valid?
    assert_includes mismatched.errors[:account_id], "is not this customer's account"
    assert_equal 0, Subscription.where(account_id: ACCOUNT_B, customer_id: customer_a.id).count,
      "the refused write must not have left a row"
  end

  # **update.** The same guard from the delivery side: a user-owned customer can
  # hold no subscription at all, because which account a user belongs to is
  # identity's fact and no event carrying it is in this build's `consumes`.
  test "update: a user-owned customer cannot be turned into an account's subscription" do
    user_owned = Customer.create!(
      owner_type: "User", owner_id: "33333333-3333-4333-8333-333333333333", processor: "stripe"
    )

    row = Subscription.new(
      account_id: ACCOUNT_A, customer: user_owned, plan: shared_plan,
      processor_subscription_id: "sub_FAKEuserownedAAAAAAAAA", status: "active"
    )

    assert_not row.valid?
    assert_includes row.errors[:customer], "is not an account, and a subscription is billed to an account"
  end

  # **write.** The event is what a consumer acts on, so an event carrying the
  # wrong account is a cross-tenant write one layer further out. Asserted on the
  # *value*, not on its absence: a test that only checked "B's account is not in
  # the payload" would pass on an event with no account at all.
  test "write: the event a customer's creation publishes names that customer's own account" do
    create_account_customers

    event = OutboxEvent.where(subject: customer_a.id).sole

    assert_equal "billing.customer.created", event.event_type
    assert_equal ACCOUNT_A, event.data.dig("owner", "id")
    assert_equal "Account", event.data.dig("owner", "type")
    refute_includes event.data.to_json, ACCOUNT_B,
      "an event about account A must not carry account B anywhere in its payload"
  end

  # **write.** The same for the delivery path, where the account is derived rather
  # than supplied: the emitted payload's `account_id` is `customer.owner_id` for
  # the customer that delivery actually resolved.
  test "write: the event a delivery publishes names the account it resolved" do
    create_account_customers
    shared_plan

    deliver_subscription_created(subscription_id: "sub_FAKEdeliveryAAAAAAAAA", customer: customer_a, event_id: "evt_FAKEdelivery1")

    row = Subscription.find_by!(processor_subscription_id: "sub_FAKEdeliveryAAAAAAAAA")
    # **By subject, not by `for_processor_event`.** The lifecycle's start payload
    # is `core_payload` plus `started_at` and deliberately carries **no**
    # `processor_event_id` — the same omission that makes the duplicate-creation
    # index in `outbox_events_processor_event_id_idx` unreachable for a start.
    # Looking the event up by the processor event id therefore finds nothing, and
    # the honest fix is the subject, which is this service's own subscription id.
    event = OutboxEvent.find_by!(subject: row.id)

    assert_equal "billing.subscription.started", event.event_type
    assert_equal ACCOUNT_A, event.data.fetch("account_id")
    assert_equal customer_a.id, row.customer_id
    refute_includes event.data.to_json, ACCOUNT_B,
      "an event resolved to account A must not carry account B anywhere in its payload"
  end

  # **list.** The outbox is the one collection in this service that is *not* read
  # back by account — there is no route and no query, because the publisher loop
  # does not exist yet. Asserting zero reads is what stops "the outbox is tenant
  # data" being assumed rather than checked, and it is the answer to the brief's
  # "or outbox events".
  test "list: nothing in this service reads an outbox row back by account" do
    create_account_customers

    assert_equal 0, Rails.application.routes.routes.count { |route|
      route.path.spec.to_s.include?("outbox")
    }, "a route that exposes the outbox is a new account-scoped read and is not in the entry point matrix"

    # The account is carried *inside* `data`, not as a column, so there is no
    # account to scope a query by even if one were written today.
    refute_includes OutboxEvent.column_names, "account_id"
    assert_equal 1, OutboxEvent.where(subject: customer_a.id).count
  end

  # --- list: the cursor, which is the one client-supplied token on a list ----

  # A cursor is the only value a caller supplies to a collection read, and it is
  # the one place a list could carry another account's data out by accident. It
  # carries an instant and a uuid and nothing else — no price, no customer, no
  # account — so a leaked or replayed cursor discloses nothing.
  #
  # The second half is the operational half: because a cursor is unsigned (there
  # is no shared secret in this service yet), a caller can *mint* one. So the
  # property that matters is that a minted cursor can only choose a position,
  # never widen the query. Asserted by pinning the decoded shape.
  test "list: a cursor carries a position and an identifier, and no account's billing data" do
    create_account_subscriptions

    decoded = JSON.parse(Base64.urlsafe_decode64(mint_cursor_for(subscription_a)))

    # The whole of it: two keys, an instant and a uuid. No account, no customer,
    # no plan, no amount — so a cursor that leaks, is logged, or is replayed by a
    # third party discloses nothing about the account it was minted from.
    assert_equal %w[at id], decoded.keys.sort
    assert_equal subscription_a.id, decoded.fetch("id")
    assert_kind_of String, decoded.fetch("at")
    assert_equal 2, decoded.size, "a cursor with a third key is carrying something it has no business carrying"
  end

  # The operational half of the same fact, and the reason it matters more than it
  # looks. `CursorPaging`'s own comment is explicit: the cursor is base64url and
  # **not** signed, because there is no shared secret in this service yet, so a
  # caller can mint one. A mintable cursor is only safe because of what a cursor
  # can do — it chooses a *position* in a query the server already built, and
  # cannot widen it.
  #
  # So the property is pinned on the query, not on the token: a cursor minted for
  # one account's row pages the collection it was given and cannot introduce a
  # predicate. `CursorPaging#apply_cursor` is a single `where` over a keyset and
  # names no model, which is what makes that true — and the next assertion is what
  # stops a future `where` from adding one.
  test "list: a cursor is a keyset, and a keyset cannot widen the query it pages" do
    create_account_subscriptions

    source = Rails.root.join("app/controllers/concerns/cursor_paging.rb").read
    keyset = source[/def apply_cursor\b.*?\n    end/m]

    assert_includes keyset, "scope.where("
    assert_includes keyset, "(created_at, id)"
    refute_match(/\b(?:Customer|Plan|Subscription)\b/, keyset,
      "`apply_cursor` now names a model. A cursor is client-supplied and unsigned, so a " \
      "model name here would be a caller choosing what the query is about.")
  end

  # --- the delete kind, and why it is empty ---------------------------------

  # The brief counts read, list, update and delete. **Delete is zero**, and the
  # reason is a fact about the service rather than an omission from a table:
  # nothing in `app/` destroys a row. A service that scopes its reads and forgets
  # its deletes is the common shape, so the assertion belongs here as well as in
  # the structural file — one proves the router serves no `DELETE`, the other
  # proves the code contains no `destroy`.
  test "delete: there is nothing to scope, because this service destroys nothing" do
    create_account_subscriptions

    assert_equal 0, destroyable_entry_points,
      "app/ grew a destroy. That is a delete, it needs an account scope, and the " \
      "entry point matrix needs a row for it."
    assert_equal 2, Subscription.count, "both accounts' rows are present and intact"

    # `cancel` is a state transition, not a deletion, and the routes file says so
    # in a comment: a DELETE that does not delete is a lie about the method. The
    # nearest thing to a delete is therefore a cancellation, which is an `update`.
    assert_equal %w[trialing active past_due], Subscription::ACTIONABLE_STATUSES
  end

  # --- the counts this file claims ------------------------------------------

  # The negative tests above, by the operation they cover — **derived from the
  # test names**, not kept in a list beside them. A list is a second copy of the
  # file that can disagree with it, and the direction it would disagree in is the
  # one nobody notices: a negative test added to `read` leaving the table saying
  # two, with the report quoting the table.
  #
  # The convention is the test's own name: `test "<kind>: <what it proves>"`.
  # Deriving from the names means the count and the coverage cannot drift apart,
  # and a test whose name has no kind is a test the count does not see — which
  # the next assertion catches.
  test "meta: this file's negative tests are counted from their names, by operation" do
    assert_equal({ "read" => 2, "list" => 3, "write" => 2, "update" => 4, "delete" => 1 },
                 breakdown(self.class.negative_test_kinds))
  end

  # Every negative test names the operation it covers. Without this, a test
  # written without a prefix would simply be missing from the breakdown above and
  # the tally would still add up.
  test "meta: every negative test names the operation it covers" do
    unlabelled = self.class.negative_test_methods.reject { |method| method.to_s.match?(/\Atest_[a-z_]+:/) }

    assert_empty unlabelled.map { |method| method.to_s.delete_prefix("test_") },
      "these tests carry no \"<kind>:\" prefix, so the breakdown above does not count " \
      "them. Name them \"read: …\", \"list: …\", \"write: …\", \"update: …\" or \"delete: …\", " \
      "or \"meta: …\" if the test is about this file rather than about an account."
  end

  # And the operation it names is one this repository knows. A test tagged `patch`
  # would otherwise be counted into a bucket nothing asserts.
  test "meta: every operation a negative test names is one of the five kinds" do
    unknown = self.class.negative_test_kinds.reject { |kind| OPERATION_KINDS.include?(kind) }

    assert_empty unknown,
      "these negative tests name an operation outside #{OPERATION_KINDS.inspect}: #{unknown.inspect}"
  end

  # The bookkeeping tests are held to their own count, so "the breakdown excludes
  # meta:" is a fact about this file rather than a convention nobody checks. If
  # this number moves, a test is about the file and should be renamed, and the
  # coverage number above should not move with it.
  test "meta: the six tests about this file are the ones excluded from its coverage" do
    assert_equal 6, self.class.bookkeeping_test_methods.size
    assert_equal 12, self.class.negative_test_methods.size
    assert_equal self.class.declared_test_methods.size,
                 self.class.bookkeeping_test_methods.size + self.class.negative_test_methods.size
  end

  # **Delete has one negative test and no entry point.** That is the whole of it,
  # and the two numbers are asserted together so a reader is never left guessing
  # whether the empty cell means "covered" or "not looked at".
  test "meta: delete is one negative test over zero entry points, and the reason is recorded" do
    assert_equal 0, destroyable_entry_points
    assert_equal 1, breakdown(self.class.negative_test_kinds).fetch("delete"),
      "the delete negative test is the one that says there is nothing to delete. If a " \
      "second appeared, this service has grown a destroy and the entry point matrix " \
      "needs a row for it."
  end

  test "meta: the operation vocabulary is the five kinds, in the order the report quotes them" do
    assert_equal %w[read list write update delete], OPERATION_KINDS
  end

  private
    # A tally with every kind present, including the ones with no rows. `tally`
    # omits an absent key, and the omitted key is the one a report most needs to
    # state out loud — here, `delete`.
    def breakdown(kinds)
      OPERATION_KINDS.index_with { |kind| kinds.count(kind) }
    end

    # How many places in `app/` destroy a row, read from the source rather than
    # from the entry point matrix — so this file stands alone and so the two
    # agree for two independent reasons.
    #
    # **Word-boundary, not a leading dot.** The ordinary spelling of a destroy is
    # a bare `destroy` inside a model method, and a pattern written as
    # `\.destroy` counts only the `obj.destroy` form — so it would report zero for
    # a model that has a `destroy` in a method of its own, which is the shape a
    # destroy actually arrives in. That pattern was here and was wrong, and the
    # mutation harness is what found it.
    def destroyable_entry_points
      Dir[Rails.root.join("app/**/*.rb")].sum { |path|
        File.read(path).scan(/\b(?:destroy|destroy_all|delete_all)\b/).size
      }
    end

    # A delivery of `customer.subscription.created` for `subscription_id`, naming
    # `customer`. Built from the committed fixture so the shape is one Stripe
    # actually sends, with the four fields a subscription is resolved by moved
    # onto the rows under test.
    #
    # The event's own `id` is merged into the body, which is what
    # `Webhooks::StripeController` does in production — the delivery's id and the
    # payload that arrived with it are one value. A helper that varied one without
    # the other would arrange a state Stripe never sends, and the outbox's unique
    # index over `processor_event_id` would then turn a correct test into a
    # duplicate-delivery refusal.
    def deliver_subscription_created(subscription_id:, customer:, event_id:)
      body = JSON.parse(stripe_fixture("customer.subscription.created"))
      object = body.dig("data", "object")

      body["id"] = event_id
      object["id"] = subscription_id
      object["customer"] = customer.processor_customer_id
      object["metadata"] = { "anywaye_customer_id" => customer.id }
      object.dig("items", "data", 0, "price")["id"] = shared_plan.processor_price_id
      object["plan"]["id"] = shared_plan.processor_price_id

      Webhooks::Ingestion.new(processor: :stripe, event_id: event_id, type: body["type"], payload: body).call
    end

    # The same shape `CursorPaging#encode_cursor` produces: base64url of
    # `{at, id}` with no padding. Minted here rather than taken off a response,
    # because the property under test is the cursor's **contents**, and a request
    # would only prove the controller can produce one — which
    # `requests/v1/subscriptions_test.rb` already covers. Minting it directly is
    # also the harder case: it is what an attacker would do, and it must yield
    # the same two keys.
    def mint_cursor_for(record)
      Base64.urlsafe_encode64(
        { "at" => record.created_at.utc.iso8601(6), "id" => record.id }.to_json,
        padding: false
      )
    end
end
