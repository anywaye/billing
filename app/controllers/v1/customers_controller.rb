module V1
  # /v1/customers — the billing-side record of something identity knows about.
  #
  # # Scoped by the caller's account, and it always was able to be
  #
  # Every query here goes through `Customer.for_account`, which matches
  # `owner_type: "Account"` and `owner_id: <the token's account_id>`. A caller
  # authenticated as account A therefore gets A's customers and nothing else:
  #
  #   * `GET /v1/customers` returns a page of **A's** customers. Before the token
  #     existed it returned every customer's, which is the visible half of the
  #     defect billing-12 measured and this packet closes.
  #   * `GET /v1/customers/:id` and `PATCH /v1/customers/:id` resolve inside that
  #     scope, so another account's uuid is **404** — the same answer an id that
  #     names nothing gets. Not 403: a 403 says "this exists, you may not have it",
  #     which is an enumeration oracle over uuids a caller can walk.
  #   * `POST /v1/customers` **ignores `owner_type`/`owner_id` in the body** and
  #     writes the caller's own account onto the row. This is the one place where a
  #     body field and a claim could disagree, and the claim wins — core's
  #     authorization rule is "`account_id` for tenancy. Every query is scoped by
  #     `account_id` from the token, never from the request body." Honouring the
  #     body here would let any authenticated caller mint a customer owned by
  #     somebody else, which is a cross-tenant write wearing a `POST`.
  #
  # **A `User`-owned customer is no longer creatable through `/v1`,** and that is a
  # deliberate consequence rather than an oversight: a user-owned customer has no
  # account to scope by, so a row like that would be unreachable from the surface
  # that made it. It remains reachable by `owner_type`/`owner_id` on the models, and
  # by the delivery path, which resolves it by processor id. Recorded in
  # `README.md`; the `Customer` model still models both owner types.
  class CustomersController < BaseController
    def index
      render_page(paginate(Customer.for_account(current_account_id)), ->(customer) { customer.as_json })
    end

    def show
      render json: customer_record, status: :ok
    end

    def create
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      customer = Customer.new(customer_attributes)

      if customer.save
        render json: customer, status: :created, location: "/v1/customers/#{customer.id}"
        remember_response(customer.as_json)
      else
        render_validation_failure(customer)
      end
    end

    def update
      customer = customer_record
      customer.assign_attributes(customer_params)

      if customer.save
        render json: customer, status: :ok
      else
        render_validation_failure(customer)
      end
    end

    private
      # `find` rather than `find_by`, and **inside `for_account`**: a row in another
      # account raises `RecordNotFound` exactly as a row that does not exist does,
      # and both render the same fixed 404 sentence. `uuid_param!` runs first, so an
      # id that could never name a row is that same answer — all three are one
      # document, which is what makes a 404 safe to reuse for another account's row.
      #
      # The scope is named at the call site rather than extracted into a `scoped`
      # helper because the helper is one more hop between a reader and the fact that
      # this query is scoped — and this is the line a reviewer looks at to decide
      # whether account A can read account B's customer. The cost is the scope
      # appearing three times, which is the point.
      def customer_record
        @customer_record ||= Customer.for_account(current_account_id).find(uuid_param!(params[:id]))
      end

      # A fixed attribute list rather than the whole body: an unrecognised field
      # is not an error here, it is a field this version does not have, and
      # letting it through would mean `owner_type` could be rewritten by a
      # request that only meant to change an email address.
      def customer_params
        params.permit(:processor, :processor_customer_id, :email, :application_key, metadata: {})
      end

      # What `create` builds, which is `customer_params` **plus** the owner the
      # token named.
      #
      # The split from `customer_params` is the point. `update` deliberately cannot
      # reach these two columns — a customer's owner is part of the key the
      # `(owner_type, owner_id, processor)` index is built on, so moving one is a
      # delete and a create — while `create` needs them and must take them from
      # somewhere this service controls. `owner_type` is the constant because a
      # customer this surface creates is always billed to an account; see the class
      # comment on why no `User` row is created here.
      def customer_attributes
        customer_params.merge(owner_type: "Account", owner_id: current_account_id)
      end
  end
end
