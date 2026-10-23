# The caller of a `/v1` request, as far as this service can tell.
#
# courier's `Courier.Principal` is the same idea and its moduledoc says why it is a
# struct rather than a bare account id: "what courier knows about a caller is
# visible in one place, and adding a field later does not change the shape of every
# call site." billing's version carries the same three facts and adds the two that
# this service's queries actually need.
#
# ## What is on it, and what is deliberately not
#
#   * `subject` — the `sub` claim, the user's uuid. Used for the idempotency key's
#     `principal` column, which is why `IdempotencyKey::PRINCIPAL` is no longer a
#     constant: core scopes an idempotency key to `(endpoint, principal, key)`, and
#     a surface with no caller had nothing to scope it to.
#   * `account_id` — the tenancy key. **Every** `/v1` query is scoped by it and by
#     nothing else, and it is required rather than optional: a token without one is
#     refused at the door, because "no account" and "an account I could not read"
#     must not both be answers to the same request.
#   * `scopes` — the capability set, from the space-separated `scope` claim.
#     Read, and **not yet enforced**: core's vocabulary (`invoices:write`) is not
#     in this build's `consumes` and no client holds one. It is parsed here so the
#     day a capability check is added there is one predicate to write, and so a
#     claim this service ignores is not silently ignored *twice*.
#
# **There is no role, and that is deliberate.** core says "Services do not parse
# roles out of a `roles` claim — they check `scopes`, or ask identity." A `role`
# field here would be a thing nothing reads.
#
# ## The account is a claim, never a parameter
#
# `account_id` is not a query parameter and not a body field, on any endpoint. A
# caller that could name its account in the request could name somebody else's, and
# this service has no way to tell the difference — which is the whole of the defect
# billing-12 measured and this packet closes. `Identifiers::UUID` validates the
# shape on the way in, so a claim that is not an account uuid cannot become a
# principal at all rather than becoming one that scopes nothing.
class Principal
  # One caller's identity. Frozen, because it is read on every query and a mutable
  # principal is a principal some later code can quietly rewrite.
  def self.build(claims, issuer:)
    payload = claims.transform_keys(&:to_s)

    account_id = payload["account_id"].to_s
    raise Identity::Invalid, NO_ACCOUNT unless Identifiers::UUID.match?(account_id)

    new(
      subject: payload["sub"].to_s,
      account_id: account_id,
      scopes: scope_set(payload["scope"]),
      issuer: issuer
    )
  end

  # Why this service is talking, and not the operator who set it up.
  #
  # **`identity` does not issue a singular `account_id` on a user token.** It
  # issues `accounts`, an **array** of `{account_id, name, slug, role, personal}`,
  # and its own `internal/oidc/profiles.go` says why: "a user of a anywaye product
  # is a member of a personal account and usually of several team accounts, and a
  # token carrying one of them would be wrong for all the others." Core's
  # conventions ask for `account_id`, singular. The two disagree, and the
  # disagreement is a DECISION NEEDED in `anywaye.yml` rather than something to
  # paper over.
  #
  # **The tempting fix is the cross-tenant bug.** Taking `accounts[0]` — or the
  # personal one, or "whichever sorts first" — produces a tenancy key nobody
  # chose, and a user in a personal account and four team accounts would have
  # every request answered against whichever entry happened to be first. That is
  # a silent cross-tenant read, and it is worse than refusing: it is a lockout
  # that *looks* like it works. So the array is not accepted here, and the
  # consequence is stated rather than hidden: **until the two repos agree on one
  # tenancy claim, a token identity actually issues to a user is refused, and
  # `/v1` answers 401.** Fail-closed is the right direction for a disagreement
  # nobody has ruled on; a guess is not.
  #
  # A user token would also need the `accounts` scope to carry the array at all,
  # so a token without it has no account fact in it in either shape.
  NO_ACCOUNT = "token names no account: this service requires a singular " \
               "`account_id` claim, which identity does not issue on a user " \
               "token (it sends `accounts`, an array). Recorded in anywaye.yml; " \
               "the first entry of an array is not a tenancy key."

  # **A missing account is a refusal and never a default.** An absent `account_id`
  # must not read as "the caller's own account" or as "no account, allow it", and
  # it must not fall back to `sub` — `sub` is a *user*, and keying tenancy on it
  # turns a bug in one service into a cross-tenant read, which is exactly what
  # identity's own README says about guard's `limitKey` fallback and refuses to
  # do. "No account" and "an account I could not read" must not both be answers
  # to the same request.

  # The space-separated `scope` string RFC 9068 registers. An absent claim is an
  # empty set, **never** everything: a claim this service cannot read must not read
  # as a grant.
  def self.scope_set(claim)
    claim.to_s.split(/\s+/).reject(&:empty?).uniq.freeze
  end

  attr_reader :subject, :account_id, :scopes, :issuer

  def initialize(subject:, account_id:, scopes: [], issuer: nil)
    @subject = subject
    @account_id = account_id
    @scopes = scopes
    @issuer = issuer
    freeze
  end

  def scope?(name)
    scopes.include?(name.to_s)
  end

  # The `(endpoint, principal, key)` triple's middle term. The subject rather than
  # the account: two users in one account are two callers, and a replay under one
  # user's key must not answer for the other's.
  def idempotency_principal
    subject
  end

  # Deliberately **not** `to_s`, `inspect` or `as_json`: a principal carries an
  # account uuid and a subject, and this service's redaction boundary has an
  # explicit rule about identifiers reaching a span. `to_s` is not overridden so a
  # stray interpolation into a log line cannot be fixed by accident.
  def ==(other)
    other.is_a?(Principal) && other.subject == subject && other.account_id == account_id
  end
  alias eql? ==

  def hash
    [ subject, account_id ].hash
  end
end
