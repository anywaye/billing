# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Cafaye
  module Generators
    # Writes core's outbox table into a host application's migrations.
    #
    #   rails generate cafaye:outbox
    #
    # The table belongs to the service — core's wording is "one table, in the
    # publishing service's own database, in its own migration" — so this copies
    # the reference DDL rather than creating it behind the service's back at
    # boot. A service that wants a different column list runs the generator,
    # edits the file, and says why in its own commit; a library that created the
    # table itself would make that impossible.
    #
    # The generated migration is the reference DDL translated into the
    # `ActiveRecord::Migration` DSL, and `test/rails_integration_test.rb` asserts
    # that every CHECK constraint survives the trip. A service that used the
    # generator has to end up with the same table as one that copied the file.
    class OutboxGenerator < ::Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the cafaye outbox table, from core's column list."

      def create_migration_file
        # One migration, and never a second one. A service that runs the generator
        # twice gets one file, because two migrations both creating
        # `outbox_events` only fails on a fresh database in staging — which is to
        # say, on the one database nobody recreated by hand.
        existing = Dir[File.join(destination_root, "db", "migrate", "*_create_outbox_events.rb")]

        if existing.any?
          say_status :identical, "db/migrate/*_create_outbox_events.rb (already present)", :blue
          return
        end

        migration_template "create_outbox_events.rb", "db/migrate/create_outbox_events.rb"
      end
    end
  end
end
