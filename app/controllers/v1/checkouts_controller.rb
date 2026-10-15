module V1
  # /v1/checkouts — the checkout door that answers immediately.
  #
  # ## Two doors, and why they are different
  #
  # `POST /v1/subscriptions` is the production door: it asks
  # `Processor::StripeClient` for a hosted Checkout session, writes nothing, and
  # the subscription row arrives when the processor's webhook says one exists.
  # That is the only door a deployment with a real Stripe account ever needs.
  #
  # This door goes through `Checkout::Session` and
  # `Processor::FakeClient`, so the processor answers from parameters and the
  # checkout **completes here**: a customer, a plan, and a subscription that is
  # `active` (or `trialing`) when the response is rendered. It exists for the
  # developer, the demo, and the CI suite that cannot hold a Stripe key — a
  # checkout path whose only proof is a live processor is a checkout path nobody
  # can run twice.
  #
  # ## Why it is gated off in production
  #
  # A door that fabricates an `active` subscription from a request body is a
  # free-subscription door the day it is reachable in a deployment somebody can
  # call. So it answers **404** — the door does not exist, not "you may not
  # pass" — unless `BILLING_FAKE_PROCESSOR_ENABLED` is set, and the 404 is the
  # same document a uuid naming nothing gets, so a caller learns nothing about
  # the deployment's configuration from it.
  #
  # ## What is shared, and what is not
  #
  # `Subscriptions::Lifecycle` is still the only writer of the row, exactly as
  # on the webhook path: the fake's answer is turned into the same normalised
  # delivery a processor event would carry and handed to the same state machine,
  # so a checkout-completed subscription and a webhook-completed one are the
  # same fact. What differs is the timing — this door's 201 carries a row,
  # because a row exists.
  class CheckoutsController < BaseController
    def create
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      return render_not_found unless fake_door_enabled?

      customer = billable_customer
      plan = sellable_plan
      return render_refusals if refused?
      return if performed?

      outcome = Checkout::Session.new(customer: customer, plan: plan, quantity: quantity).complete
      return render_refusal(outcome) if outcome.failed?

      body = serialize(outcome.subscription)
      render json: body, status: :created
      remember_response(body)
    end

    private
      def initialize(...)
        super
        @refusals = []
      end

      # The 404 a uuid naming nothing gets, and the answer this door gives a
      # deployment it is not enabled in. `Rails.env` first: a default-on flag
      # would make "production forgot to set it" an open door, which is the one
      # direction this service's configuration never errs.
      def fake_door_enabled?
        return true if Rails.env.development? || Rails.env.test?

        ActiveModel::Type::Boolean.new.cast(ENV["BILLING_FAKE_PROCESSOR_ENABLED"].to_s) || false
      end

      # The fixed sentence `render_not_found`'s rescue uses, so a disabled door
      # is byte for byte the answer a uuid naming nothing gets.
      def render_not_found
        render_problem(:not_found, detail: "No record matches that identifier.")
      end

      # The same resolution `POST /v1/subscriptions` uses, and for the same
      # reason: a `customer_id` naming another account's row resolves to nil
      # inside `Customer.for_account`, so a checkout can only ever be made for
      # the caller's own customer. The scope is the resolution, not a check
      # after it.
      def billable_customer
        customer = find_or_refuse(:customer_id) { Customer.for_account(current_account_id).find_by(id: _1) }
        return if customer.nil?
        return refuse(:validation_failed, "customer_id", "belongs to a user, and a subscription is billed to an account") unless customer.owner_type == Subscription::BILLABLE_OWNER_TYPE

        customer
      end

      def sellable_plan
        plan = find_or_refuse(:plan_id) { Plan.find_by(id: _1) }
        return if plan.nil?
        return refuse(:validation_failed, "plan_id", "is not for sale") unless plan.active
        return refuse(:validation_failed, "plan_id", "has no processor price, so it cannot be bought") if plan.processor_price_id.blank?

        plan
      end

      # A field that must be a uuid, resolved or refused. Absent is a 422 naming
      # the field; present but not a uuid is the 404 `uuid_param!` gives a path
      # segment, decided before any query.
      def find_or_refuse(field)
        value = params[field]
        return refuse(:validation_failed, field, "is required") if value.blank?
        raise ActiveRecord::RecordNotFound unless Identifiers::UUID.match?(value.to_s)

        yield(value) || refuse(:validation_failed, field, "is not a record this service has")
      end

      def quantity
        return 1 if params[:quantity].blank?

        value = params[:quantity]
        return value.to_i if value.is_a?(Integer) || value.to_s.match?(/\A[1-9][0-9]*\z/)

        refuse(:validation_failed, "quantity", "must be a positive whole number of seats")
        1
      end

      Refusal = Data.define(:code, :field, :message) do
        def as_error
          { "field" => field, "code" => "invalid" }
        end
      end

      def refuse(code, field, message)
        @refusals ||= []
        @refusals << Refusal.new(code: code, field: field, message: message)
        nil
      end

      def refused?
        @refusals.any?
      end

      # The outcome's reason is the lifecycle's own, verbatim, because
      # "the account does not match" and "canceled is terminal" are different
      # facts and flattening them would make the second invisible. The body is
      # the same problem document every other 422 on `/v1` is.
      def render_refusal(outcome)
        detail = "the checkout could not be completed: #{outcome.reason}"
        render_problem(:validation_failed, detail: detail)
      end

      def render_refusals
        render_problem(
          :validation_failed,
          detail: @refusals.map(&:message).join("; "),
          errors: @refusals.map(&:as_error)
        )
      end

      # The subscription, with its plan's price in integer minor units — the one
      # wire representation for an amount, and the same one `GET
      # /v1/subscriptions/:id` renders.
      def serialize(subscription)
        subscription.as_json.merge("price" => subscription.plan.price.to_h)
      end
  end
end
