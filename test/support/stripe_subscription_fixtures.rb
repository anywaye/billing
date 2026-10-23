# The local records a Stripe subscription fixture resolves to.
#
# A subscription event is only acted on when it can be attached to a anywaye
# customer and a anywaye plan — a subscription this service did not sell is not one
# it bills, and the delivery is recorded as `unknown_customer` / `unknown_plan`
# rather than matched to whoever shares an id. Every spec that ingests a
# subscription fixture therefore needs those two records, with the *processor's*
# ids on them, or the event is refused and the spec is asserting a refusal it did
# not mean to arrange.
#
# These helpers live here rather than in each spec so that the ids the fixtures
# carry and the ids the records answer to cannot drift apart in four places. The
# ids are the ones in the committed fixtures, so a fixture edited without its
# helpers failing is a fixture nobody looked at.
#
# ## A second row gets a second id, and why that is a correctness fix
#
# Both helpers used to default to one constant, so a spec that asked for two
# customers or two plans got **two rows claiming one `cus_`/`price_`**. That was
# invisible until billing-13 made both columns unique
# (`customers_processor_customer_id_idx`, `plans_processor_price_id_idx`), at
# which point every spec building more than one of either failed with a unique
# violation.
#
# The collision was never something a spec *meant* to arrange — it was an artifact
# of a shared default — so the fix is the default, not 85 call sites. **The first
# call in a test still gets the fixture's id**, because that id is load-bearing: it
# is what the committed subscription fixtures carry, and a spec that ingests one
# needs its customer and its plan to answer to it. Every later call gets a
# distinct, obviously-fake id, so a spec can build the second plan it needs
# without its rows colliding.
#
# The on-sale price ids are a **closed list on purpose**, because
# `FakeStripeAPI` refuses a price it does not know and a plan whose price the
# fake has never heard of is a plan the processor turns down. A spec that puts a
# plan on sale therefore needs its price to be one this processor knows. The list
# and `FakeStripeAPI::KNOWN_PRICES` are two literals that have to agree, so
# `test/support/fixture_processor_ids_test.rb` asserts that they do rather than
# leaving the agreement to a comment.
module StripeSubscriptionFixtures
  PROCESSOR_CUSTOMER_ID = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze
  PROCESSOR_PRICE_ID = "price_1PZQaBcDeFgHiJkLmNoPqR2".freeze

  # **The account the suite's tokens act as, and not a literal here.**
  #
  # `/v1` is scoped by the token's `account_id`, so a fixture owned by any other
  # account is invisible to every request in the suite — a request spec would pass
  # asserting the *lock* while the behaviour it meant to test was never reached.
  # Naming the identity module's constant makes that impossible to get wrong in one
  # place, and `test/requests/v1/customers_test.rb` and
  # `test/requests/v1/subscriptions_test.rb` inherit it rather than each pinning
  # their own copy.
  #
  # Distinct from `TwoAccounts::ACCOUNT_A/B` on purpose: those are the pair
  # `test/tenant/` compares against, and the suite's ordinary authenticated account
  # being one of them would make a cross-account spec's "the caller's own row" and
  # "the other account's row" the same row.
  ACCOUNT_ID = TestSupport::TestIdentity::Account

  # Extra processor ids for the *second* and later rows of a kind, handed out in
  # order. Obviously fake like everything else here, and named rather than
  # generated because `FakeStripeAPI` has to know them.
  ADDITIONAL_CUSTOMER_IDS = %w[
    cus_FAKEmemberBBBBBBBBBBBBBB
    cus_FAKEteammateBBBBBBBBBBBBB
    cus_FAKEguestBBBBBBBBBBBBBBB
  ].freeze

  ADDITIONAL_PRICE_IDS = %w[
    price_FAKEteamplanBBBBBBBBB
    price_FAKElateralplanBBBBBBB
    price_FAKEcheaperplanBBBBBBB
    price_FAKEyearlyplanBBBBBBBB
  ].freeze

  # The anywaye customer a fixture's subscription belongs to. `account_owner_type`
  # is a parameter only so a spec can arrange the one case where a customer cannot
  # hold a subscription at all.
  #
  # `processor_customer_id` defaults to the next unused id rather than to a
  # constant: see the class comment for why a second row must not claim the same
  # `cus_`.
  def create_stripe_customer(account_id: ACCOUNT_ID, owner_type: "Account", processor_customer_id: nil)
    Customer.create!(
      owner_type: owner_type,
      owner_id: owner_type == "Account" ? account_id : SecureRandom.uuid,
      processor: "stripe",
      processor_customer_id: processor_customer_id || next_processor_customer_id
    )
  end

  def create_stripe_plan(price: Billing::Money.new(1900, "USD"), interval: "month", processor_price_id: nil, slug: nil, name: nil)
    # One index, read once: the name and the slug are the same row and a counter
    # that advanced between them would number them differently.
    index = next_index

    Plan.create!(
      name: name || "Pro #{index}",
      slug: slug || "pro-#{index}",
      price: price,
      interval: interval,
      processor_price_id: processor_price_id || next_processor_price_id
    )
  end

  private
    # One counter for both, so a spec's first customer and its first plan are
    # numbered 1 and the ids read in the order they were built.
    def next_index
      @stripe_rows = @stripe_rows.to_i + 1
    end

    # The fixture's id first, then the extras. Raises rather than wrapping onto
    # the first id again: a spec that has built more rows than there are ids for
    # has asked for a collision, and quietly handing out a duplicate is how the
    # two versions of this file diverged in the first place.
    def next_processor_customer_id
      available = [ PROCESSOR_CUSTOMER_ID, *ADDITIONAL_CUSTOMER_IDS ]
      taken = Customer.where.not(processor_customer_id: nil).pluck(:processor_customer_id)

      pick_next(available, taken, "customer")
    end

    def next_processor_price_id
      available = [ PROCESSOR_PRICE_ID, *ADDITIONAL_PRICE_IDS ]
      taken = Plan.where.not(processor_price_id: nil).pluck(:processor_price_id)

      pick_next(available, taken, "price")
    end

    def pick_next(available, taken, kind)
      id = available.find { |candidate| !taken.include?(candidate) }
      raise "no unused processor #{kind} id left; add one to StripeSubscriptionFixtures" if id.nil?

      id
    end
end

module ActiveSupport
  class TestCase
    include StripeSubscriptionFixtures
  end
end
