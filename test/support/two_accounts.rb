# Two accounts, side by side, for the tenant-isolation specs.
#
# ## Why a shared module and not a helper in each file
#
# The negative tests only mean something if **the same two accounts** are on both
# sides of every comparison, and an id that drifts between two files is a
# comparison that quietly stops being one. So the accounts, their customers, their
# plans and their subscriptions are built here once, and every spec reaches for
# the same pair.
#
# ## The ids are obviously fake, and that is the point
#
# `cus_FAKE…`, `sub_FAKE…`, `price_FAKE…`, `evt_FAKE…` and the account uuids are
# all generated per run from a fixed prefix. A Stripe id is a real-looking string
# in a real system, and a fixture that looks like one is a fixture somebody could
# mistake for a captured production value. These cannot be mistaken for anything:
# `FAKE` is in the prefix of every processor id, and the account uuids are the
# constant `1111…` / `2222…` pair, which is not a value any system mints.
#
# ## What is built, and what each account is for
#
# Each account gets **one account-owned customer**, which is the only kind that
# can hold a subscription (`Subscription::BILLABLE_OWNER_TYPE`), and one live
# subscription on a shared plan. One plan is deliberately shared: the
# live-uniqueness index is over `(account_id, plan_id)`, so the interesting case is
# two accounts on the *same* plan, and a fixture that gave each its own plan could
# not tell a correct index from a missing one.
module TwoAccounts
  # The two accounts. Fixed, distinguishable at a glance, and not uuids anything
  # mints — a spec failure that prints one is readable rather than ambiguous.
  ACCOUNT_A = "11111111-1111-4111-8111-111111111111".freeze
  ACCOUNT_B = "22222222-2222-4222-8222-222222222222".freeze

  # Obviously-fake processor ids. The prefix is the marker; nothing after it is a
  # real object in any processor.
  CUSTOMER_A = "cus_FAKEaccountAAAAAAAAAAAAAAAA".freeze
  CUSTOMER_B = "cus_FAKEaccountBBBBBBBBBBBBBBBB".freeze
  SUBSCRIPTION_A = "sub_FAKEaccountAAAAAAAAAAAAAAAA".freeze
  SUBSCRIPTION_B = "sub_FAKEaccountBBBBBBBBBBBBBBBB".freeze
  PRICE = "price_FAKEshaRedplanAaaaaaaaaaaaaa".freeze

  # `A` or `B`, so a failure message says which side of the comparison moved
  # without printing anything either account owns.
  def account_a = ACCOUNT_A
  def account_b = ACCOUNT_B

  # One account-owned customer per account, each answering to its own processor
  # id. The pair is the whole point: a lookup that cannot tell them apart is the
  # defect the delivery specs are about, and they have to be distinguishable by
  # the columns the code actually queries.
  def create_account_customers
    @account_customers ||= {
      a: Customer.create!(owner_type: "Account", owner_id: ACCOUNT_A, processor: "stripe", processor_customer_id: CUSTOMER_A),
      b: Customer.create!(owner_type: "Account", owner_id: ACCOUNT_B, processor: "stripe", processor_customer_id: CUSTOMER_B)
    }
  end

  def customer_a = create_account_customers.fetch(:a)
  def customer_b = create_account_customers.fetch(:b)

  # **One** plan, shared by both accounts.
  #
  # A plan is catalogue and is not account-scoped, so sharing it is correct. It is
  # also what makes the live-uniqueness index testable: with a plan per account,
  # `(account_id, plan_id)` would be satisfied by `plan_id` alone and a dropped
  # `account_id` from the index would go unnoticed.
  def shared_plan
    @shared_plan ||= Plan.create!(
      name: "Shared plan",
      slug: "shared-plan-#{SecureRandom.hex(6)}",
      price: Billing::Money.new(1_900, "USD"),
      interval: "month",
      processor_price_id: PRICE
    )
  end

  # One live subscription per account, on the shared plan, each with its own
  # processor subscription id. The two rows are the objects every "did this touch
  # the other account?" assertion is measured against.
  def create_account_subscriptions(status: "active")
    @account_subscriptions ||= begin
      plan = shared_plan
      {
        a: Subscription.create!(
              account_id: ACCOUNT_A, customer: customer_a, plan: plan,
              processor_subscription_id: SUBSCRIPTION_A, status: status
            ),
        b: Subscription.create!(
              account_id: ACCOUNT_B, customer: customer_b, plan: plan,
              processor_subscription_id: SUBSCRIPTION_B, status: status
            )
      }
    end
  end

  def subscription_a = create_account_subscriptions.fetch(:a)
  def subscription_b = create_account_subscriptions.fetch(:b)

  # A per-row digest of the stored columns, keyed by id — safe to put in a failure
  # message.
  #
  # The cross-account specs want to assert that a write "changed nothing" for the
  # other account, and the obvious way to write that is to compare the rows —
  # which, on failure, prints a whole other account's subscription, price and
  # status into the test output. **This digest exists so that never happens.** A
  # `sha256` per row says "byte-identical" without saying what the bytes were, and
  # `drifted_ids` below then names *which* ids moved rather than what they held.
  #
  # It is a **hash keyed by id**, not a single digest, because "which rows moved"
  # and "did anything move" are two questions and only the first needs the
  # individual values. A single digest over a whole set answers the second and
  # makes the first unanswerable — `before[record.id]` on a String is a substring
  # search, which is `nil` for every uuid, so every row reports as drifted and the
  # assertion is true on every run including the ones it exists to catch.
  #
  # `created_at` and `updated_at` are excluded on purpose: `updated_at` moves on
  # every write, so including it would make "the row was touched" indistinguishable
  # from "the row's billing data changed", and the former is not what these specs
  # are about.
  def fingerprint(records)
    Array(records).to_h do |record|
      record.reload
      columns = record.attributes.except("id", "created_at", "updated_at").sort.to_h

      [ record.id, Digest::SHA256.hexdigest(columns.inspect) ]
    end
  end

  # The ids of the rows whose stored columns moved, so a failure names **which**
  # row changed without naming anything about it.
  def drifted_ids(before, records)
    Array(records).select { |record| fingerprint([ record ]).fetch(record.id) != before[record.id] }.map(&:id)
  end
end

module ActiveSupport
  class TestCase
    include TwoAccounts
  end
end
