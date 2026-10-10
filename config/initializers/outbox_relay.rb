# The outbox publisher's boot condition, in one place.
#
# billing drains `outbox_events` onto the fleet's NATS bus when — and only when
# — `NATS_URL` names a broker. Unset, nothing starts: the rows accumulate in
# the table, which is the whole point of writing them to a table, and the boot
# log says so rather than leaving an operator to wonder. There is deliberately
# no `NoopPublisher` equivalent wired in here; see `Outbox::Relay`.
#
# `after_initialize`, because this names an application constant and a
# `config/initializers` file runs before the autoloader is set up — the same
# seam `otel.rb` uses for the same reason.
Rails.application.config.after_initialize do
  # The condition is a deployment's, not the environment's: it is read from the
  # real environment at boot in every environment except the test suite, where
  # the relay is inert. That inversion is deliberate. The suite boots this
  # application many times — once per parallel worker — and a developer with a
  # local broker would otherwise publish fixture rows onto their fleet bus from
  # inside a test run. The behaviour the tests assert is `Relay`'s, exercised
  # directly against a broker double; this file is the wiring, and the wiring is
  # what must not run twice.
  outbox_relay =
    if Rails.env.test?
      nil
    else
      Outbox::Relay.start_from_environment(logger: Rails.logger)
    end

  # Tied to the process: a shutdown asks the loop to finish its pass and join
  # it. A pass in flight at exit leaves its rows unpublished, which is correct —
  # unmarked rows are claimable, and the next process picks them up.
  if outbox_relay
    at_exit do
      outbox_relay.stop
    end
  end
end
