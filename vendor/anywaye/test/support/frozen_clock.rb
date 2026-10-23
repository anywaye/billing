# frozen_string_literal: true

module TestSupport
  # A clock the tests control.
  #
  # Nothing in this suite reads the wall clock. An assertion that contains a
  # real timestamp is an assertion that fails on a different day than it was
  # written, and the two things most likely to carry one here — a JWT's `exp`
  # and a JWKS cache's TTL — are exactly the things a test has to push past a
  # boundary to prove anything. `bin/prime` must pass in CI at 3am and on a
  # developer's laptop, and it does because the clock is a constant.
  module FrozenClock
    NOW = Time.utc(2026, 9, 30, 4, 19, 0)

    def now
      NOW
    end

    # Seconds from now, the unit a JWT's `exp` and `nbf` are written in.
    def seconds_from_now(offset)
      NOW.to_i + offset
    end

    # Advances the clock by whole seconds. No test ever sleeps; the clock moves
    # because the test says it does.
    def advance_clock(seconds)
      NOW + seconds
    end
  end
end
