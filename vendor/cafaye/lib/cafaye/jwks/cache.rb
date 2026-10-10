# frozen_string_literal: true

module Cafaye
  module Jwks
    # The key-set cache, and the refresh budget.
    #
    # This class is the answer to "a refresh storm from bad tokens must not
    # become an outbound request per request", and it is bounded three times
    # over, because one bound is not enough:
    #
    # 1. **The TTL.** A fetched set is reused for `ttl` seconds. One fetch per
    #    TTL per process, whatever the traffic.
    # 2. **The minimum refresh interval.** A `kid` that is not in a *fresh* set
    #    buys **one** forced refresh, and then no forced refresh at all for
    #    `min_refresh_interval`. This is the bound that matters, because a `kid`
    #    is attacker-chosen and "refresh on unknown kid" is a rule a caller can
    #    trigger per request. A rule a caller can trigger per request is an
    #    amplifier aimed at identity, not a fallback.
    # 3. **The negative cache.** An unknown `kid` is remembered for
    #    `unknown_kid_ttl` and answered from memory. This is what stops the same
    #    bad token being the thing that triggers a refresh, and it is
    #    size-capped, because an attacker who sends ten thousand distinct `kid`s
    #    would otherwise grow this hash by ten thousand entries and turn the fix
    #    for a network problem into a memory problem.
    #
    # A forced refresh is also refused for a set this request has just read: the
    # load that populated the cache already saw every key identity is currently
    # publishing, so asking again is asking the same question twice.
    #
    # On a failed fetch the previous set is **kept**, not discarded. Throwing the
    # cache away turns a dependency blip into a total authentication outage, and
    # a stale key set is worth more than no key set: at worst a key that has
    # since been rotated out still verifies, and the next successful refresh
    # replaces it. The first load has nothing to fall back to, so it raises.
    #
    # Thread-safe: two threads cannot both decide to refresh and both fetch.
    class Cache
      # How many unknown `kid`s are remembered. Bounded because the input is
      # attacker-chosen. 1024 is far more than a real rotation in an
      # `unknown_kid_ttl` window and far less than a memory problem.
      DEFAULT_MAX_NEGATIVE_ENTRIES = 1024

      def initialize(fetcher:, clock:, ttl:, unknown_kid_ttl:, min_refresh_interval:,
                     max_negative_entries: DEFAULT_MAX_NEGATIVE_ENTRIES)
        @fetcher = fetcher
        @clock = clock
        @ttl = ttl
        @unknown_kid_ttl = unknown_kid_ttl
        @min_refresh_interval = min_refresh_interval
        @max_negative_entries = max_negative_entries
        @mutex = Mutex.new
        @key_set = nil
        @fetched_at = nil
        @last_forced_at = nil
        @unknown_kids = {}
      end

      # The verification key for `kid`, or `nil` when the set does not publish
      # one.
      #
      # @raise [Cafaye::Errors::JwksUnavailable] only when there is no key set
      #   at all and one cannot be fetched.
      def verification_key_for(kid)
        @mutex.synchronize { resolve(kid) }
      end

      # The number of `kid`s currently remembered as unknown. Read by the
      # suite's budget assertions, and the number an operator wants when a
      # service is being aimed at.
      def negative_cache_size
        @mutex.synchronize { @unknown_kids.size }
      end

      private

      def resolve(kid)
        # The negative cache is read first, and it is load-bearing rather than
        # decorative: a `kid` this process has already refused is answered from
        # memory without consulting the refresh arithmetic at all. What that
        # costs is a genuine rotation that lands inside the window and is
        # refused for up to `unknown_kid_ttl`. Thirty seconds by default, and
        # that is the whole reason the window is short and configurable.
        return nil if recently_unknown?(kid)

        key_set, freshly_loaded = current_key_set
        key = key_set.verification_key_for(kid)
        return key if key

        # `freshly_loaded` means this request already read every key identity is
        # publishing, so a refresh now is the same question twice. The interval
        # is the other half: even on a set loaded earlier, one forced refresh per
        # interval is the budget.
        may_refresh = !freshly_loaded && refresh_allowed?
        remember_unknown(kid)
        return nil unless may_refresh

        @last_forced_at = @clock.call
        rotated = load_or_keep
        key = rotated.verification_key_for(kid)
        # The refresh found it after all, a rotation that landed between the load
        # and this request. Forgetting the entry keeps the negative cache from
        # refusing a key this process has just proved exists.
        forget(kid) if key
        key
      end

      # Whether this process has already refused `kid` inside its window.
      #
      # Note the direction: this answers "do I already know this is unknown",
      # and an entry that has outlived `unknown_kid_ttl` is forgotten on the way
      # past so it cannot be answered from a stale memory. An earlier version of
      # this method returned the inverse and the negative cache was written but
      # never read, which the refresh-budget test caught as one extra fetch per
      # unknown `kid`.
      def recently_unknown?(kid)
        seen_at = @unknown_kids[kid]
        return false if seen_at.nil?

        forget(kid) if (@clock.call - seen_at) >= @unknown_kid_ttl
        @unknown_kids.key?(kid)
      end

      def forget(kid)
        @unknown_kids.delete(kid)
        nil
      end

      # The cached set, loading it if the TTL has run out. The second value says
      # whether *this* call did the loading, which is what stops a fresh load
      # from being followed immediately by a forced refresh.
      def current_key_set
        return [ @key_set, false ] if fresh?

        [ load_or_keep, true ]
      end

      def fresh?
        !@key_set.nil? && (@clock.call - @fetched_at) < @ttl
      end

      def refresh_allowed?
        @last_forced_at.nil? || (@clock.call - @last_forced_at) >= @min_refresh_interval
      end

      # A fetch, keeping the previous set if it fails.
      def load_or_keep
        @key_set = @fetcher.fetch
        @fetched_at = @clock.call
        @key_set
      rescue Errors::JwksUnavailable
        raise if @key_set.nil?

        @key_set
      end

      def remember_unknown(kid)
        @unknown_kids.delete(kid)
        @unknown_kids[kid] = @clock.call
        # Insertion order is the order of arrival, so dropping the front evicts
        # the oldest. Entries older than their own window go too, which keeps a
        # long-lived process from holding `kid`s it will never see again.
        @unknown_kids.shift while @unknown_kids.size > @max_negative_entries
        @unknown_kids.delete_if { |_, seen_at| (@clock.call - seen_at) >= @unknown_kid_ttl }
        nil
      end
    end
  end
end
