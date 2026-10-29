module V1
  # /v1/subscriptions — the lifecycle a client drives.
  #
  # ## Nothing here decides a subscription's state
  #
  # Every mutating action asks the processor to do something and returns. The
  # subscription row changes when a webhook says it did, which is the rule the rest
  # of this service follows: the processor is the party that can bill, and a local
  # row that disagreed with it would grant entitlements nobody is paying for.
  # Concretely:
  #
  #   * `create` writes **no** subscription. It creates a Checkout session, because a
  #     subscription does not exist until the payment completes — and the 201 carries
  #     the session, not a resource. Inventing a local row here would mean a sixth
  #     status meaning "we asked", which is a state no processor can report.
  #   * `cancel` and `change_plan` move the processor's subscription and leave the row
  #     alone. A response claiming the subscription is canceled before the processor
  #     has said so would be a lie a client could act on.
  #
  # The exception to "the response is the row" is `change_plan`, which returns a
  # `plan_change` object alongside it. Without it a client has no way to learn that a
  # downgrade is scheduled for the end of the period rather than applied now — the
  # rule lives in `Subscriptions::PlanChange` and is otherwise invisible until a
  # webhook lands. It describes the decision this request made; it is not state, and
  # the subscription's own fields do not change.
  #
  # ## Every problem in a body is reported at once
  #
  # `refuse` records rather than renders, and an action renders once at the end. A
  # client that sent three wrong fields gets three failures, not the first one three
  # times — which is the same rule `render_validation_failure` follows for a model's
  # own errors.
  #
  # # Scoped by the caller's account
  #
  # `index` pages `Subscription.for_account(current_account_id)` — this account's
  # subscriptions, not every subscription in the database — and **every** row-addressed
  # action resolves inside that same scope: `show`, `cancel`, `change_plan`,
  # `entitlements` and `upcoming_invoice`. So a uuid naming another account's subscription is a **404**,
  # byte for byte the answer a uuid naming nothing gets. Not 403: a 403 says "this
  # exists, you may not have it", and a caller walking uuids would learn exactly
  # which subscriptions exist without reading one. Absence, never refusal.
  #
  # `create` names the customer by `customer_id` in the body still — a Checkout
  # session needs a buyer, and the body is where a buyer goes — but the customer is
  # resolved **inside the account scope**, so a `customer_id` naming another
  # account's customer is refused as "not a record this service has" rather than
  # billing that account's card. It refuses a `User`-owned customer for the reason
  # it always did: which account a user belongs to is identity's fact, and no event
  # carrying it is in this build's `consumes`.
  class SubscriptionsController < BaseController
    Refusal = Data.define(:code, :field, :message) do
      def as_error
        { "field" => field, "code" => "invalid" }
      end
    end

    def index
      render_page(paginate(Subscription.for_account(current_account_id)), ->(subscription) { serialize(subscription) })
    end

    def show
      render json: serialize(subscription_record), status: :ok
    end

    def entitlements
      render json: entitlements_for(subscription_record), status: :ok
    end

    # The processor's projection of the next invoice for one of the caller's
    # subscriptions: what the customer will be charged at the renewal, before it
    # is paid. A read, and the only one on this controller that asks the
    # processor a question rather than telling it to do something — which is why
    # its refusals are the read's refusals, not the mutators'.
    #
    # A canceled subscription is a 409 before the processor is asked: the
    # processor has stopped collecting, and a projection of a charge that will
    # not happen is not a figure this service may invent. Every other status is
    # left to the processor — `past_due` and `unpaid` are collection states, and
    # whether there is still a period to invoice is the processor's answer.
    def upcoming_invoice
      subscription = subscription_record
      guard_invoicable!(subscription)
      return render_refusals if refused?

      invoice = ask_processor(field: "subscription_id", message: "has no upcoming invoice at the payment processor") do
        processor_for(subscription).upcoming_invoice(
          processor_subscription_id: subscription.processor_subscription_id,
          processor_customer_id: subscription.customer.processor_customer_id
        )
      end
      return render_refusals if refused?
      return if performed?

      render json: upcoming_invoice_response(subscription, invoice), status: :ok
    end

    def create
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      customer = billable_customer
      plan = sellable_plan
      return render_refusals if refused?
      return if performed?

      session = checkout_for(customer, plan)
      return render_refusals if refused?
      return if performed?

      body = {
        "checkout_session_id" => session.id,
        "checkout_url" => session.url,
        "customer_id" => customer.id,
        "plan_id" => plan.id
      }

      render json: body, status: :created
      remember_response(body)
    end

    # The self-serve portal: where a customer goes to change a card or read an
    # invoice at the processor. This service has no payment-method form of its
    # own by design — a card it stored would be a card it holds — so the whole
    # answer is a URL, and the `return_url` is the caller's.
    #
    # The door is the customer's, resolved through a subscription this caller
    # owns: `subscription_record` is the scoped resolution, and the customer comes
    # off the row rather than from the body, so a caller cannot open a portal for
    # another account's customer even by naming one.
    #
    # **The `return_url` is an absolute http(s) URL, and the first version of
    # this endpoint got it wrong**: it demanded a path "on this service's
    # origin", which is wrong for the processor — measured 2026-10-16, Stripe
    # refuses a relative path with `InvalidRequestError: Not a valid URL`, so
    # the portal could never open — and wrong for the topology, because the
    # browser that follows the redirect cannot resolve this service's own
    # address at all. It is the same rule as the checkout's `success_url`, and
    # the same validator.
    def payment_method
      subscription = subscription_record
      guard_owned_by_the_real_processor!(subscription)
      return render_refusals if refused?
      return_url = return_url(:return_url)
      return render_refusals if refused?

      url = ask_processor(field: "subscription_id", message: "has no portal session at the payment processor") do
        processor_for(subscription).billing_portal_url(
          processor_customer_id: subscription.customer.processor_customer_id,
          return_url: return_url
        )
      end
      return render_refusals if refused?
      return if performed?

      render json: { "payment_method_url" => url }, status: :ok
    end

    def cancel
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      subscription = subscription_record
      at_period_end = at_period_end_param
      guard_cancellable!(subscription, at_period_end)
      guard_owned_by_the_real_processor!(subscription)
      return render_refusals if refused?
      return if performed?

      ask_processor do
        processor.cancel_subscription(
          processor_subscription_id: subscription.processor_subscription_id,
          at_period_end: at_period_end
        )
      end
      return render_refusals if refused?
      return if performed?

      body = serialize(subscription)
      render json: body, status: :ok
      remember_response(body)
    end

    def change_plan
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      subscription = subscription_record
      target = sellable_plan
      guard_changeable!(subscription)
      guard_owned_by_the_real_processor!(subscription)
      return render_refusals if refused?
      return if performed?

      change = Subscriptions::PlanChange.new(from: subscription.plan, to: target)
      ask_processor do
        processor.apply_plan_change(
          processor_subscription_id: subscription.processor_subscription_id,
          price_id: change.to_price_id,
          proration_behavior: change.proration_behavior
        )
      end
      return render_refusals if refused?
      return if performed?

      body = serialize(subscription).merge("plan_change" => plan_change(target, change))
      render json: body, status: :ok
      remember_response(body)
    end

    private
      attr_reader :processor

      def initialize(...)
        super
        @processor = Processor::StripeClient.current
        @refusals = []
      end

      # `find`, not `find_by`, and **inside `for_account`**: a row in another account
      # raises `RecordNotFound` exactly as a row that does not exist does, and both
      # render the same fixed 404 sentence. `uuid_param!` runs first so an id that
      # could never name a row is that same answer — all three are one document,
      # which is what makes a 404 safe to reuse for another account's row.
      #
      # **Every row-addressed action on this controller comes through here** —
      # `show`, `cancel`, `change_plan`, `entitlements`, `upcoming_invoice` — so
      # the mutating directions,
      # which are the expensive ones, cannot be the one somebody forgot to scope.
      # The scope is written out rather than hidden behind a `scoped` helper because
      # this is the line a reviewer reads to decide whether account A can cancel
      # account B's subscription.
      def subscription_record
        @subscription_record ||= Subscription.for_account(current_account_id).find(uuid_param!(params[:id]))
      end

      def checkout_for(customer, plan)
        success_url = return_url(:success_url)
        cancel_url = return_url(:cancel_url)
        return if refused?

        ask_processor do
          processor.create_checkout_session(
            plan_price_id: plan.processor_price_id,
            customer_reference: customer.id,
            success_url: success_url,
            cancel_url: cancel_url,
            processor_customer_id: customer.processor_customer_id.presence
          )
        end
      end

      # Where the buyer lands after paying (or backing out), and it is the
      # CALLER's URL because it is the app's page. Required by Stripe on a
      # hosted session — the omission was a production-breaking defect the
      # live recording caught — and validated here as an absolute http(s)
      # URL so a relative path is a 422 naming the field rather than a
      # session Stripe refuses with a message about its own parameters.
      #
      # `cancel_url` is optional: the client sends the success URL when the
      # caller names no other, which is a page the buyer can use rather than
      # whatever a dashboard default happens to be.
      def return_url(field)
        value = params[field]
        return nil if field == :cancel_url && value.blank?
        return refuse(:validation_failed, field.to_s, "is required") if value.blank?

        uri = begin
          URI.parse(value.to_s)
        rescue URI::InvalidURIError
          nil
        end
        unless uri && %w[http https].include?(uri.scheme) && uri.host.present?
          return refuse(:validation_failed, field.to_s, "must be an absolute http(s) URL")
        end

        value.to_s
      end

      # One place the processor is asked, and the one place its refusals become
      # answers. `Subscriptions::PlanChange::Unpriced` and
      # `Billing::Money::CurrencyMismatchError` are raised by the plan-change *rule* rather
      # than by the processor and mean the same thing here — this request cannot be
      # carried out as asked — so they are handled alongside.
      #
      # The field and message a processor refusal is filed under are the caller's,
      # because they name what *that* endpoint's client sent: the mutators' client
      # sent a `plan_id` the processor would not apply, and the upcoming invoice's
      # client sent a `subscription_id` the processor has no invoice for. The
      # defaults are the mutators', which are three of the four call sites.
      def ask_processor(field: "plan_id", message: "could not be applied by the payment processor")
        yield
      rescue Processor::Error, Subscriptions::PlanChange::Error, Billing::Money::CurrencyMismatchError => e
        refuse_processor(e, field: field, message: message)
      end

      # The customer the request named, and the check that it is one this service can
      # bill **and one this caller owns**. A user-owned customer is refused rather than
      # resolved to an account: which account a user belongs to is identity's fact,
      # and no event carrying it is in this build's `consumes`.
      #
      # The scope is the load-bearing half. `Customer.for_account` means a
      # `customer_id` naming another account's row resolves to `nil` here, so the
      # refusal is the same "not a record this service has" a bogus uuid gets —
      # absent, not refused, and carrying nothing about whether the row exists. A
      # Checkout session is created against `customer_reference: customer.id` and
      # `customer.processor_customer_id`, so an unscoped lookup would have opened a
      # payment against another account's saved Stripe customer.
      def billable_customer
        customer = find_or_refuse(:customer_id) { Customer.for_account(current_account_id).find_by(id: _1) }
        return if customer.nil?

        unless customer.owner_type == Subscription::BILLABLE_OWNER_TYPE
          return refuse(:validation_failed, "customer_id", "belongs to a user, and a subscription is billed to an account")
        end

        customer
      end

      # A plan that is for sale and that the processor can actually charge for. Both
      # checks are here rather than at the processor: a request this service knows
      # cannot work should not be sent and answered with someone else's error.
      def sellable_plan
        plan = find_or_refuse(:plan_id) { Plan.find_by(id: _1) }
        return if plan.nil?
        return refuse(:validation_failed, "plan_id", "is not for sale") unless plan.active
        return refuse(:validation_failed, "plan_id", "has no processor price, so it cannot be bought") if plan.processor_price_id.blank?

        plan
      end

      # A field that must be a uuid, resolved or refused.
      #
      # Absent is a 422 naming the field, because the caller left something out and
      # the body was otherwise fine. Present but not a uuid is a 404, decided before
      # any query — the same rule `uuid_param!` applies to a path segment, and for
      # the same reason: Postgres parses a `uuid` column before Rails gets to decide
      # whether a row exists.
      def find_or_refuse(field)
        value = params[field]
        return refuse(:validation_failed, field, "is required") if value.blank?
        raise ActiveRecord::RecordNotFound unless Identifiers::UUID.match?(value.to_s)

        yield(value) || refuse(:validation_failed, field, "is not a record this service has")
      end

      # A 422 naming the field, not a 400. The body parsed as JSON; it is a field
      # that is missing or wrong, which is core's 422 and not its 400 — a 400 is for
      # syntax the caller could not have known about.
      def at_period_end_param
        return refuse(:validation_failed, "at_period_end", "is required and must be true or false") unless params.key?(:at_period_end)

        value = params[:at_period_end]
        return value if value == true || value == false

        refuse(:validation_failed, "at_period_end", "must be true or false")
      end

      # Two things refuse a cancellation, and they are different.
      #
      # A `canceled` or `unpaid` subscription is a conflict: the request collides
      # with something that already happened, or the processor has stopped collecting
      # and is about to cancel it itself.
      #
      # A `past_due` subscription asked to cancel *at the period end* is a 422 rather
      # than a silent immediate cancellation: there is no further period to serve, and
      # quietly doing something other than what the caller asked is worse than
      # refusing.
      def guard_cancellable!(subscription, at_period_end)
        unless Subscription::ACTIONABLE_STATUSES.include?(subscription.status)
          return refuse(:conflict, "status", "is #{subscription.status}, so there is nothing to cancel")
        end

        return unless at_period_end && subscription.status == "past_due"

        refuse(:validation_failed, "at_period_end",
          "must be false for a past_due subscription: there is no further period to serve")
      end

      def guard_changeable!(subscription)
        return if Subscription::ACTIONABLE_STATUSES.include?(subscription.status)

        refuse(:conflict, "status", "is #{subscription.status}, so its plan cannot be changed")
      end

      # The one status an upcoming invoice does not exist for. A `canceled`
      # subscription collides with something that has already happened, so it is
      # a 409 rather than a 422 — and it is refused *here* rather than at the
      # processor, because the processor's own error for a canceled subscription
      # is not a fact this service should ask it for.
      def guard_invoicable!(subscription)
        return if subscription.status != "canceled"

        refuse(:conflict, "status", "is canceled, so there is no upcoming invoice")
      end

      # The upcoming invoice, with every figure the processor's own and the one
      # wire representation for an amount: an integer of minor units, a currency
      # upper case, and never a decimal string.
      #
      # `tax` is the single figure this service computes, and it is a difference
      # between two processor figures — `total - total_excluding_tax` — made
      # here for display and for no other purpose. It is never stored, never sent
      # to the processor and never used for a decision, so it is not the thing
      # this service's no-arithmetic rule is about: that rule is a figure
      # *computed to send to the processor*, or one invented that the processor
      # did not state, and a display delta between two of the processor's own
      # figures is neither. Omitting it instead would leave a response whose
      # parts do not add up when tax is present, which is the worse lie.
      def upcoming_invoice_response(subscription, invoice)
        {
          "subscription_id" => subscription.id,
          "period_end" => Time.at(invoice.period_end).utc.iso8601,
          "currency" => invoice.currency.upcase,
          "line_items" => Array(invoice.lines).map { |line| upcoming_invoice_line(line) },
          "subtotal" => invoice.subtotal,
          "tax" => invoice.total - invoice.total_excluding_tax,
          "total" => invoice.total
        }
      end

      # One line of the invoice, in the same minor-unit shape. The unit amount
      # is the processor's own figure, read rather than derived from the line
      # total: a quantity greater than one is where a derived figure would go
      # wrong, and the processor states it outright.
      #
      # **Stripe's 2025 line items have no `price` object at all** — the
      # recording caught this builder reading `line.price.unit_amount`, an
      # accessor that no longer exists, so every real preview would have
      # raised NoMethodError in production. The figure now lives at
      # `pricing.unit_amount_decimal` as a decimal STRING in minor units
      # ("1900"), and `unit_amount_of` is the one place it becomes an
      # Integer — refusing rather than truncating a fractional one, because
      # a truncated figure is one the processor never stated.
      def upcoming_invoice_line(line)
        {
          "description" => line.description,
          "period" => {
            "start" => Time.at(line.period.start).utc.iso8601,
            "end" => Time.at(line.period.end).utc.iso8601
          },
          "quantity" => line.quantity,
          "unit_amount" => unit_amount_of(line),
          "amount" => line.amount,
          "currency" => line.currency.upcase
        }
      end

      def unit_amount_of(line)
        decimal = BigDecimal(line.pricing.unit_amount_decimal.to_s)
        unless decimal.frac.zero?
          raise Processor::StripeClient::Unrepresentable,
            "the processor stated a unit amount of #{decimal.to_s("F")}, which is not a whole number of minor units"
        end

        decimal.to_i
      end

      # What the processor said, in the two words a client can act on. `immediately`
      # means the processor is billing the difference now; `period_end` means nothing
      # is carried forward and the move lands at the renewal.
      def plan_change(target, change)
        {
          "plan_id" => target.id,
          "effective" => change.timing.to_s,
          "proration" => change.proration_behavior
        }
      end

      # What the plan grants, and whether the subscription is granting it. A canceled
      # subscription grants nothing, which is the only answer here that is a decision
      # rather than a copy of the plan; a `past_due` or `unpaid` one still grants,
      # because the processor's grace period is a product decision and not this
      # service's to take away.
      def entitlements_for(subscription)
        entitlements = subscription.plan.entitlements
        granted = subscription.grants_entitlements?

        {
          "subscription_id" => subscription.id,
          "plan_id" => subscription.plan_id,
          "plan_slug" => subscription.plan.slug,
          "status" => subscription.status,
          "granted" => granted,
          "features" => granted ? Array(entitlements["features"]) : [],
          "limits" => granted ? (entitlements["limits"] || {}) : {}
        }
      end

      # The subscription, with its plan's price in integer minor units. The one wire
      # representation for an amount, and the same one everywhere it is returned —
      # `Plan#price` is a `Billing::Money` and `Billing::Money#to_h` is the crossing shape.
      def serialize(subscription)
        subscription.as_json.merge("price" => subscription.plan.price.to_h)
      end

      # THE PROCESSOR THAT OWNS THIS ROW, resolved per row rather than per
      # request, and the reason is a defect this service has already had: asking
      # the wrong processor produces the processor's error for a subscription
      # that processor never held. The walk's own fake-door subscription
      # answered "has no upcoming invoice at the payment processor", when the
      # truth was that the FAKE held it and Stripe knew nothing.
      #
      # The marker is the processor's own id prefix
      # (`Processor::FakeClient::SUBSCRIPTION_PREFIX`), not a column: a second
      # place for "who holds this row" to live is a second thing to disagree.
      def processor_for(subscription)
        return Processor::FakeClient.new if Processor::FakeClient.owns?(subscription.processor_subscription_id)

        processor
      end

      # THE VERBS THE DEVELOPMENT PROCESSOR DOES NOT HAVE, refused here rather
      # than at a real one.
      #
      # The fake answers two things — its own checkout, which completes now by
      # design, and the projection of a renewal it was sold a price book for.
      # It has no portal (a card form is the processor's, and the fake holds no
      # cards) and no cancel or change: both are state changes only a
      # processor's webhook can state, and the fake's own class comment is
      # explicit that it must not become a pretend Stripe, because a pretend
      # Stripe is eventually invoked by something that believes it.
      #
      # So these verbs on a fake subscription are refused BY NAME, saying which
      # processor holds and why, instead of going to Stripe and coming back
      # translated into a processor's error for a subscription Stripe never saw.
      def guard_owned_by_the_real_processor!(subscription)
        return unless Processor::FakeClient.owns?(subscription.processor_subscription_id)

        refuse(
          :validation_failed,
          "subscription_id",
          "is held by the development processor, which cannot manage a subscription: " \
          "cancel, change and the portal belong to a real one"
        )
      end

      def refuse(code, field, message)
        @refusals << Refusal.new(code: code, field: field, message: message)
        nil
      end

      def refused?
        @refusals.any?
      end



      # One 422 or 409 for everything the request got wrong, in the order the
      # problems were found. A `:conflict` is 409 and carries no `errors[]`, because
      # the request was well-formed and simply collided — the same line
      # `render_validation_failure` draws.
      def render_refusals
        conflicts = @refusals.select { |refusal| refusal.code == :conflict }
        return render_problem(:conflict, detail: conflicts.map(&:message).join("; ")) if conflicts.any?

        render_problem(
          :validation_failed,
          detail: @refusals.map(&:message).join("; "),
          errors: @refusals.map(&:as_error)
        )
      end

      # The processor is not a anywaye client, and its refusals are its own business.
      # This service's own misconfiguration is a 503 — the caller's request was fine
      # and saying otherwise would send an operator looking in the wrong place — and
      # a processor refusal is a 422 naming the field the endpoint's client sent,
      # with the processor's message logged and never returned to the caller.
      def refuse_processor(exception, field: "plan_id", message: "could not be applied by the payment processor")
        log_processor_refusal(exception)

        case exception
        when Processor::StripeClient::Unconfigured
          render_problem(:unavailable, detail: "The payment processor is not configured.")
        else
          refuse(:validation_failed, field, message)
        end
      end

      # A refusal this service reached on its own reasoning is not a processor
      # problem, and logging it as one would send an operator to the wrong system.
      def log_processor_refusal(exception)
        return if exception.is_a?(Subscriptions::PlanChange::Error) || exception.is_a?(Billing::Money::CurrencyMismatchError)

        Rails.logger.error("payment processor refused a request: #{exception.class}: #{exception.message}")
      end
  end
end
