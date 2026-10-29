require "test_helper"

class CustomerTest < ActiveSupport::TestCase
  OWNER_ID = "11111111-1111-4111-8111-111111111111"
  OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222"

  setup do
    travel_to(frozen_now)

    @customer = Customer.new(
      owner_type: "User",
      owner_id: OWNER_ID,
      processor: "stripe",
      email: "kaka@example.com"
    )
  end

  test "a customer for an identity user on stripe is valid" do
    assert @customer.valid?, @customer.errors.full_messages.to_sentence
  end

  test "a second customer may not claim a processor customer id that is taken" do
    Customer.create!(owner_type: "Account", owner_id: OTHER_OWNER_ID, processor: "stripe",
      processor_customer_id: "cus_FAKEnotmineBBBBBBBBBBBBB")

    @customer.processor_customer_id = "cus_FAKEnotmineBBBBBBBBBBBBB"

    refute @customer.valid?
    assert @customer.errors.of_kind?(:processor_customer_id, :taken),
      "the refusal has to be `:taken` and not a generic `:invalid`, or the 409 stops being a " \
      "conflict and becomes a 422 about a field the client cannot fix"
  end

  test "a processor customer id nobody holds is accepted" do
    @customer.processor_customer_id = "cus_FAKEnobodyhasitBBBBBBBBB"

    assert_predicate @customer, :valid?
  end

  test "many customers may hold no processor customer id at all" do
    Customer.create!(owner_type: "Account", owner_id: OWNER_ID, processor: "stripe")
    other = Customer.new(owner_type: "Account", owner_id: OTHER_OWNER_ID, processor: "stripe")

    assert_predicate other, :valid?
  end

  test "a customer needs no email" do
    @customer.email = nil

    assert @customer.valid?
  end

  test "a customer is not yet a Stripe customer" do
    @customer.processor_customer_id = nil
    @customer.save!

    assert_predicate @customer, :persisted?
    assert_nil @customer.reload.processor_customer_id
  end

  test "a customer requires an owner type" do
    @customer.owner_type = nil

    assert_not @customer.valid?
    assert_includes @customer.errors.attribute_names, :owner_type
  end

  test "a customer owner type is one of identity's entities" do
    @customer.owner_type = "Widget"

    assert_not @customer.valid?
    assert_includes @customer.errors.attribute_names, :owner_type
  end

  test "an account is as billable as a user" do
    @customer.owner_type = "Account"

    assert @customer.valid?
  end

  test "a customer requires an owner id" do
    @customer.owner_id = nil

    assert_not @customer.valid?
    assert_includes @customer.errors.attribute_names, :owner_id
  end

  test "a customer owner id is a uuid, because identity's are" do
    @customer.owner_id = "not-a-uuid"

    assert_not @customer.valid?
    assert_includes @customer.errors.attribute_names, :owner_id
  end

  test "a customer requires a processor" do
    @customer.processor = nil

    assert_not @customer.valid?
    assert_includes @customer.errors.attribute_names, :processor
  end

  test "a customer processor is one this service knows how to bill" do
    @customer.processor = "braintree"

    assert_not @customer.valid?
    assert_includes @customer.errors.attribute_names, :processor
  end

  test "a customer email must be deliverable" do
    @customer.email = "kaka@@example"

    assert_not @customer.valid?
    assert_includes @customer.errors.attribute_names, :email
  end

  test "customer metadata is an object, not a scalar" do
    @customer.metadata = "stripe_id cus_123"

    assert_not @customer.valid?
    assert_includes @customer.errors.attribute_names, :metadata
  end

  test "customer metadata defaults to an empty object" do
    @customer.metadata = nil

    assert @customer.valid?
    assert_equal({}, @customer.metadata)
  end

  test "one customer per owner per processor" do
    @customer.save!

    duplicate = Customer.new(owner_type: "User", owner_id: OWNER_ID, processor: "stripe")

    assert_not duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :processor
  end

  test "the uniqueness is per owner, so a second user gets a second customer" do
    @customer.save!
    other = Customer.new(owner_type: "User", owner_id: OTHER_OWNER_ID, processor: "stripe")

    assert other.valid?
  end

  test "the uniqueness is per owner, so an account and a user each get one" do
    @customer.save!
    other = Customer.new(owner_type: "Account", owner_id: OWNER_ID, processor: "stripe")

    assert other.valid?
  end

  test "customer metadata survives a round trip through the database" do
    @customer.metadata = { "tenant" => "kaka", "seats" => 3 }
    @customer.save!

    assert_equal({ "tenant" => "kaka", "seats" => 3 }, @customer.reload.metadata)
  end

  test "the wire shape nests the owner and is stable" do
    @customer.save!

    assert_equal(
      {
        "id" => @customer.id,
        "owner" => { "type" => "User", "id" => OWNER_ID },
        "processor" => "stripe",
        "processor_customer_id" => nil,
        "email" => "kaka@example.com",
        "metadata" => {},
        "created_at" => frozen_now.iso8601,
        "updated_at" => frozen_now.iso8601
      },
      @customer.as_json
    )
  end
end
