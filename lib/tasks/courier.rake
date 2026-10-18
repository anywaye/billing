# frozen_string_literal: true

namespace :courier do
  desc "Register billing's notification types in courier (receipt, payment_failed)"
  task register_types: :environment do
    Courier::TypeRegistrar.register_all!
  end
end
