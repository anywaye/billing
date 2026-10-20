require "test_helper"

# Two literals that have to agree, asserted rather than left to a comment.
#
# ## Which two
#
# `StripeSubscriptionFixtures::PROCESSOR_PRICE_ID` (and its `ADDITIONAL_PRICE_IDS`)
# is what a plan is given when a spec asks for a plan, and `FakeStripeAPI::KNOWN_PRICES`
# is what the fake processor has heard of. **A plan whose price the fake has never
# heard of is a plan the processor turns down** — that refusal is deliberate, and it
# is what makes "the processor said no" a thing the specs can arrange. So a spec
# that puts a second plan on sale has to be given a price the fake knows, and a
# spec that is not would silently be asserting a processor refusal where it meant a
# successful one.
#
# That is a real coupling, and it is a **copy** rather than a reference: the fake
# loads before the fixtures module (`test_helper.rb` requires
# `test/support/**/*.rb` in sorted order, and `fake_stripe_api` sorts first), so
# `KNOWN_PRICES` cannot read the constant at class-body time. The alternative — a
# pattern match, or the fake learning prices on demand — would let the fake accept
# anything, which is the property the refusal tests depend on.
#
# So the two are separate lists and this file is what holds them in step. Its whole
# reason to exist is that the disagreement is invisible: nothing raises, nothing
# fails, and a spec quietly tests the wrong thing.
#
# ## Why `price_new` is in there and not generated
#
# `test/services/processor/stripe_client_test.rb` names `price_new` directly, so it
# has to stay a member of the list. It is a price no fixture helper hands out, which
# is exactly what a test wants when it is naming a second plan's price itself.
class FixtureProcessorIdsTest < ActiveSupport::TestCase
  # The regression test for the change billing-13 made to these helpers, and the
  # reason it is behavioural rather than a shape check.
  #
  # Both helpers used to default to a single constant, so a spec that asked for a
  # second customer or a second plan got **two rows claiming one `cus_`/`price_`** —
  # which was invisible until `customers_processor_customer_id_idx` and
  # `plans_processor_price_id_idx` made it a unique violation, and then it took 85
  # tests in `test/requests/v1/subscriptions_test.rb` down at once. A test about the
  # *shape* of the id lists would not have caught it: the bug was never the list,
  # it was the default.
  test "two customers in one test get two ids, and both are written" do
    first = create_stripe_customer(account_id: SecureRandom.uuid)
    second = create_stripe_customer(account_id: SecureRandom.uuid)

    assert_predicate first, :persisted?
    assert_predicate second, :persisted?
    refute_equal first.processor_customer_id, second.processor_customer_id,
      "the second customer was handed the first one's `cus_`, which the unique index refuses"
  end

  test "two plans in one test get two ids, and both are written" do
    first = create_stripe_plan
    second = create_stripe_plan(price: Billing::Money.new(4_900, "USD"))

    assert_predicate first, :persisted?
    assert_predicate second, :persisted?
    refute_equal first.processor_price_id, second.processor_price_id,
      "the second plan was handed the first one's `price_`, which the unique index refuses"
  end

  test "the first plan a spec builds is the one the committed fixtures resolve against" do
    assert_equal "price_1PZQaBcDeFgHiJkLmNoPqR2", create_stripe_plan.processor_price_id
  end

  test "the first customer id a spec is given is the one the committed fixtures carry" do
    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", StripeSubscriptionFixtures::PROCESSOR_CUSTOMER_ID,
      "the first customer a spec builds has to answer to the id the committed " \
      "`customer.subscription.*` fixtures carry, or a spec that ingests one of them " \
      "resolves to nothing and asserts the `unknown_customer` refusal instead"
    assert_equal "price_1PZQaBcDeFgHiJkLmNoPqR2", StripeSubscriptionFixtures::PROCESSOR_PRICE_ID,
      "same for the plan: the first plan a spec builds has to answer to the price id " \
      "the committed fixtures carry"
  end

  test "every price a spec can be given is one the fake processor knows" do
    handed_out = [ StripeSubscriptionFixtures::PROCESSOR_PRICE_ID, *StripeSubscriptionFixtures::ADDITIONAL_PRICE_IDS ]
    unknown = handed_out - FakeStripeAPI::KNOWN_PRICES

    assert_empty unknown,
      "a plan can be created with a price the fake processor has never heard of, so a spec " \
      "that puts it on sale gets a processor refusal where it meant a successful one. " \
      "Either drop the id from #{StripeSubscriptionFixtures.name} or add it to " \
      "FakeStripeAPI::KNOWN_PRICES — #{unknown.inspect}"
  end

  test "the two lists are the same size, so a spec cannot exhaust one and silently reuse the other" do
    assert_operator FakeStripeAPI::KNOWN_PRICES.size, :>=,
      StripeSubscriptionFixtures::ADDITIONAL_PRICE_IDS.size + 1,
      "the fake knows fewer prices than the helper can hand out, so the last spec to ask " \
      "for a plan would be given a price the fake refuses"
  end

  test "every id this packet added is obviously fake" do
    added = [
      *StripeSubscriptionFixtures::ADDITIONAL_CUSTOMER_IDS,
      *StripeSubscriptionFixtures::ADDITIONAL_PRICE_IDS
    ]

    obviously_fake = added.select { |id| id.match?(/\A(?:cus|price)_FAKE/) }

    assert_equal added.size, obviously_fake.size,
      "a fixture id without FAKE in its prefix is one somebody could mistake for a captured " \
      "production value. Generated per run is fine; a plausible-looking constant is not."
  end

  # The two **originals** are exempt from that rule, and the exemption is load
  # bearing rather than an oversight: they are the ids the committed Stripe
  # fixtures carry, and a subscription delivery is only acted on when it resolves
  # to a customer and a plan through them. Renaming them to `cus_FAKE…` would stop
  # every spec that ingests a fixture from resolving, and each would then assert
  # the `unknown_customer` / `unknown_plan` refusal instead of what it meant to.
  #
  # So the rule is "any id that is *not* the committed fixture's is obviously
  # fake", and this is the test that says which two are exempt.
  test "the two real-looking ids are the committed fixtures' ids, and that is why they exist" do
    fixture = JSON.parse(stripe_fixture("customer.subscription.created")).dig("data", "object")

    assert_equal fixture["customer"], StripeSubscriptionFixtures::PROCESSOR_CUSTOMER_ID,
      "the fixture's customer id and the helper's do not match, so a spec that ingests the " \
      "fixture resolves to nothing"
    assert_equal fixture.dig("items", "data", 0, "price", "id"), StripeSubscriptionFixtures::PROCESSOR_PRICE_ID,
      "same for the plan's price id"
  end
end
