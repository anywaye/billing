module Webhooks
  # Which account a VERIFIED processor event belongs to.
  #
  # ## The problem this exists for, stated as the query it is about
  #
  # `Lifecycle#customer` and `Charges::Recorder#resolved_customer` both find a
  # customer row by an id the processor sent — the anywaye customer uuid our own
  # Checkout session put in the subscription's metadata, or the processor's own
  # `cus_…` — and learn the account from `owner_id`. That is a query whose SUBJECT
  # the account boundary does not know yet: it cannot be scoped by an account,
  # because computing the account is what the query is for. Under row level
  # security a query with no identity reads zero rows, so without a mechanism here
  # every delivery would be recorded `unknown_customer` and answered 200 — a
  # money service silently billing nobody, which is the loudest possible failure
  # mode wearing the quietest possible log line.
  #
  # ## The mechanism, and it is kit's rather than this service's
  #
  # `customers_anywaye_resolve` (`db/tenancy/account_isolation.sql`) is a `for
  # select` policy whose qualifier is the value the CALLER PRESENTED:
  #
  #     id::text = (select anywaye.current_credential_digest())
  #     or processor_customer_id = (select anywaye.current_credential_digest())
  #
  # The predicate is in the policy and not only in the caller's query, which is
  # the whole design: RLS policies combine permissively, so a policy that said
  # merely "a resolution session may select this table" would hand this path a
  # table-wide SELECT over every customer in the database. Because the policy
  # carries the same predicate the lookup carries, the honest semantics are: a
  # resolution session may read exactly the customer whose id — or whose processor
  # customer id — it presented, and nothing else.
  #
  # This class presents ONE VALUE AT A TIME and reads with it, because that is the
  # shape the mechanism has: a single transaction-local GUC, one presented value,
  # and a lookup whose predicate is that value. It is not a search over the table;
  # it is a lookup by a value the payload carried, twice, with different values.
  #
  # ## Where the values come from, and why they are read from the normaliser
  #
  # `Webhooks::StripeEvents.normalize` is already the one place in this service
  # that knows where a anywaye reference lives in a processor payload — the
  # invoice's own metadata, the subscription's (which the live shape nests under
  # `parent`), the first line item's, or a Checkout session's
  # `client_reference_id`. Reading them here a second time would be a second
  # answer to "where is the link back", and the two would drift. So this class
  # asks the normaliser, in the same order the payment path resolves a customer
  # (`anywaye_customer_id` first, the processor's id second — the order is the
  # measured fix for a first payment whose customer has no
  # `processor_customer_id` yet).
  #
  # ## What it cannot do
  #
  #   * It cannot resolve an account from a value nobody minted: the value has to
  #     be one the payload carried, and the policy only ever widens a read to the
  #     row that value names.
  #   * It cannot write. The resolve policy is `for select`; every write policy on
  #     `customers` still demands an account identity, which is set from what this
  #     class returns.
  #   * It cannot open another table. `subscriptions`, `charges` and `plans` are
  #     untouched by the resolve policy, and the lookups below run with no account
  #     identity — so a customer it cannot resolve leaves the rest of the delivery
  #     reading nothing, which is the same refusal this path already gives an
  #     event about a customer created in the processor's dashboard.
  #
  # A nil answer is a legitimate outcome and is not an error: the ingestion then
  # runs with no identity, the lifecycle refuses with `unknown_customer`, and the
  # delivery is recorded and answered 200 exactly as it is today.
  class AccountResolution
    def initialize(payload)
      @payload = payload
    end

    # The account the event names, or nil when the payload names no customer this
    # service knows. MUST be called inside a transaction: `begin_credential/1` is
    # `set_config(..., is_local => true)`, so outside one the presented value is
    # gone before the lookup that uses it — the same reason `begin_account/1`
    # needs a transaction, and `Tenancy.with_resolved_account` is the caller that
    # provides it.
    def account_id
      candidates.each do |value|
        Tenancy.begin_credential(value)

        customer = find_customer(value)
        next unless customer&.owner_type == Subscription::BILLABLE_OWNER_TYPE

        return customer.owner_id
      end

      nil
    end

    private
      attr_reader :payload

      # The ids this payload carries, in the order the payment path tries them.
      # `normalize` is nil for a type with no normaliser and raises `Ignored` for
      # the one type it deliberately does not normalise (a subscription-mode
      # Checkout session, which the subscription lifecycle restates a moment
      # later) — neither is a resolution, and neither is an error here: the
      # delivery is recorded by the ingestion exactly as it was before this class
      # existed.
      def candidates
        data = Webhooks::StripeEvents.normalize(payload) || {}
        [ data["anywaye_customer_id"], data["client_reference_id"], data["customer_id"] ].compact_blank.uniq
      rescue Webhooks::Error
        []
      end

      # The row a presented value names, by whichever column can hold it.
      #
      # The shape check is not decoration: `customers.id` is a `uuid` column, and
      # Postgres parses a uuid literal before Rails can decide whether a row
      # exists — `where id = 'cus_…'` is a 22P02 database error, not a miss. So a
      # value that cannot be one of our ids is only ever looked up as the
      # processor's, which is a string column and cannot raise.
      def find_customer(value)
        if Identifiers::UUID.match?(value.to_s)
          Customer.find_by(id: value) || Customer.find_by(processor_customer_id: value)
        else
          Customer.find_by(processor_customer_id: value)
        end
      end
  end
end
