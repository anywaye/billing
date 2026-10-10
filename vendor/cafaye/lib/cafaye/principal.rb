# frozen_string_literal: true

module Cafaye
  # The verified caller.
  #
  # Small, frozen, and explicit, because the packet asks for exactly that and
  # because of what the alternatives are. A caller handed the claims hash has to
  # know which claim names identity mints — and a guessed claim name is a
  # silently-failing authorization check, which is the single worst outcome this
  # library could have. So the claims are read once, here, against a named set,
  # and what a caller can reach is what this class lists.
  #
  # There is deliberately no `[]`, no `claims`, and no `fetch`. A claim this
  # library does not name cannot be read off a principal, so a caller cannot log
  # one by accident and cannot build an authorization decision on one it
  # guessed. `to_h` exists and is frozen, and it contains only the seven fields
  # below — that is the whole surface, asserted in `test/principal_test.rb`.
  class Principal
    # The fields a principal carries, in one place so `to_h` and `#inspect` and
    # the tests cannot disagree about what "the whole surface" means.
    FIELDS = %i[account_id audience expires_at issued_at issuer subject token_id].freeze

    attr_reader :subject, :account_id, :scopes, :expires_at, :issued_at, :issuer, :audience, :token_id

    # @param subject [String] the `sub` claim — the user, not the token.
    # @param account_id [String, nil] the tenant. `nil` when the claim is
    #   absent and the service did not require it; a service that needs tenancy
    #   asks for `require_account: true` and gets a refusal instead.
    # @param scopes [Array<String>] sorted, deduplicated, frozen. Empty means
    #   *nothing*, never *everything*: a scope gate that read an empty set as
    #   "unrestricted" would be a gate with no gate.
    def initialize(subject:, account_id:, scopes:, expires_at:, issued_at:, issuer:, audience:, token_id:)
      @subject = frozen(subject)
      @account_id = frozen(account_id)
      # Deeply frozen, not just the array. A caller that reaches into
      # `principal.scopes.first` and appends to it would otherwise mutate a
      # string this object shares with nothing in particular and that a second
      # caller's principal is holding a reference to — and "frozen" that only
      # means the container is the kind of claim a test asserts once and then
      # stops meaning.
      @scopes = scopes.map { |scope| frozen(scope) }.sort.uniq.freeze
      @expires_at = expires_at
      @issued_at = issued_at
      @issuer = frozen(issuer)
      @audience = frozen(audience)
      @token_id = frozen(token_id)
      freeze
    end

    # Whether this caller holds `scope`. An exact match on one of the scopes the
    # token carried — not a prefix, not a pattern, not a substring. `billing:read`
    # does not imply `billing:read:all`, because a rule that grows an implicit
    # hierarchy is a rule nobody can enumerate.
    def scope?(scope)
      scopes.include?(scope.to_s)
    end

    # The whole surface, and nothing else. Frozen, so a caller that hands it to
    # something that mutates its argument gets an error rather than a principal
    # nobody can reason about.
    def to_h
      { subject: @subject, account_id: @account_id, scopes: @scopes, expires_at: @expires_at,
        issued_at: @issued_at, issuer: @issuer, audience: @audience, token_id: @token_id }.freeze
    end

    def ==(other)
      other.is_a?(Principal) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    # `inspect` is a logging surface: it is what ends up in a log line when a
    # principal is in a hash, an exception message or a debugger's variable dump.
    # It lists the named fields and no claim that this class did not choose to
    # name — the canary test asserts it.
    def inspect
      "#<#{self.class.name} subject=#{@subject.inspect} account_id=#{@account_id.inspect} " \
        "scopes=#{@scopes.inspect} expires_at=#{@expires_at.iso8601}>"
    end

    private

    # `nil` passes through; a String that is already frozen is not copied.
    # `.dup.freeze` rather than `-@` because these are identifiers, and the
    # deduplicating form would put every subject this process has ever seen into
    # the interpreter's global string table.
    def frozen(value)
      return nil if value.nil?
      return value if value.frozen?

      value.dup.freeze
    end
  end
end
