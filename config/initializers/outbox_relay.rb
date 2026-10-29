Rails.application.config.after_initialize do
  outbox_relay =
    if Rails.env.test?
      nil
    else
      Outbox::Relay.start_from_environment(logger: Rails.logger)
    end

  if outbox_relay
    at_exit do
      outbox_relay.stop
    end
  end
end
