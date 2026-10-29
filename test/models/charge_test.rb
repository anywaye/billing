require "test_helper"

class ChargeTest < ActiveSupport::TestCase
  ACCOUNT_ID = "11111111-1111-4111-8111-111111111111"
  OTHER_ACCOUNT_ID = "22222222-2222-4222-8222-222222222222"

  setup do
    travel_to(frozen_now)

    @customer = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_ID, processor: "stripe",
      processor_customer_id: "cus_FAKEchargetestAAAAAAAAAAAA"
    )
    @charge = Charge.new(
      account_id: ACCOUNT_ID,
      customer: @customer,
      processor_charge_id: "ch_FAKEchargetestAAAAAAAAAAAA",
      amount: 1_900,
      currency: "USD",
      description: "Pro monthly",
      paid_at: frozen_now
    )
  end

  test "a charge with every field is valid" do
    assert @charge.valid?, @charge.errors.full_messages.to_sentence
  end


  test "a charge requires an account" do
    @charge.account_id = nil

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:account_id, :blank)
  end

  test "a charge requires a customer" do
    @charge.customer = nil

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:customer, :blank)
  end

  test "a charge may have no subscription" do
    @charge.subscription = nil

    assert_predicate @charge, :valid?
  end


  test "a charge requires a processor charge id" do
    @charge.processor_charge_id = nil

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:processor_charge_id, :blank)
  end

  test "a second charge may not claim a processor charge id that is taken" do
    @charge.save!
    duplicate = Charge.new(
      account_id: ACCOUNT_ID, customer: @customer,
      processor_charge_id: "ch_FAKEchargetestAAAAAAAAAAAA",
      amount: 1_900, currency: "USD", description: "Pro monthly", paid_at: frozen_now
    )

    refute duplicate.valid?
    assert duplicate.errors.of_kind?(:processor_charge_id, :taken),
      "the refusal has to be `:taken` and not a generic `:invalid`, or the 409 stops being a " \
      "conflict and becomes a 422 about a field the client cannot fix"
  end


  test "a charge requires an integer amount" do
    @charge.amount = 19.0

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:amount, :not_an_integer)
  end

  test "a charge of zero is valid" do
    @charge.amount = 0

    assert_predicate @charge, :valid?
  end

  test "a negative amount is refused" do
    @charge.amount = -1

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:amount, :greater_than_or_equal_to)
  end

  test "a charge requires a currency" do
    @charge.currency = nil

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:currency, :blank)
  end

  test "a currency that is not three uppercase letters is refused" do
    @charge.currency = "usdt"

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:currency, :invalid_format)
  end


  test "a charge requires a description" do
    @charge.description = nil

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:description, :blank)
  end

  test "a charge requires a paid_at" do
    @charge.paid_at = nil

    assert_not @charge.valid?
    assert @charge.errors.of_kind?(:paid_at, :blank)
  end


  test "for_account returns this account's charges and nobody else's" do
    @charge.save!
    other = Charge.create!(
      account_id: OTHER_ACCOUNT_ID, customer: @customer,
      processor_charge_id: "ch_FAKEchargetestBBBBBBBBBBBB",
      amount: 1_900, currency: "USD", description: "Pro monthly", paid_at: frozen_now
    )

    assert_equal [ @charge.id ], Charge.for_account(ACCOUNT_ID).pluck(:id)
    assert_equal [ other.id ], Charge.for_account(OTHER_ACCOUNT_ID).pluck(:id)
    assert_empty Charge.for_account(SecureRandom.uuid)
  end
end
