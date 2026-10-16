# `db/schema.rb` cannot express the account boundary, and the schema load is what
# builds a fresh database.
#
# THE HOLE THIS CLOSES, and it is the one path where the boundary would silently
# not be there. `db:prepare` builds a database that does not exist yet by loading
# `db/schema.rb` — not by migrating — and the load marks every migration applied.
# So on a fresh database `db:migrate/20261016120000_account_isolation.rb` never
# runs, and since `schema.rb` cannot carry a `create policy`, a row level security
# bit, a function or a grant, the database comes up with the three tables and no
# boundary at all. Production's entrypoint is `./bin/rails db:prepare`
# (`bin/docker-entrypoint`), so that is not a hypothetical: a first deploy onto an
# empty database would serve every account's rows to every account, with the
# application's own `for_account` as the only defence — the state this change
# exists to leave behind.
#
# WHAT IT DOES. Runs the same two DDL files the migration runs, through
# `Tenancy::Substrate.install!`, which also asserts `cafaye.unprotected_tables()`
# is empty and refuses to finish otherwise. Idempotent: every statement in those
# files either converges (`protect_table` drops and recreates its policies,
# `create or replace function`, `create schema if not exists`) or is preceded by a
# `drop … if exists`, so running it after a migration that already installed the
# boundary changes nothing.
#
# ENHANCED, NOT REPLACED, and it runs AFTER Rails' own work — the schema has to be
# loaded before there are tables to protect. `db:prepare` and `db:schema:load` are
# both enhanced because `db:prepare` calls `DatabaseTasks.load_schema` directly
# rather than the rake task, so enhancing one would leave the other, which is the
# one production actually runs, unprotected. A third path — the suite's
# `maintain_test_schema!` — reaches neither rake task and installs the same thing
# from `test/test_helper.rb`.
namespace :db do
  namespace :tenancy do
    desc "Install the account boundary (row level security) into this database"
    task install: :environment do
      Tenancy::Substrate.install!
      puts "db:tenancy:install — subscriptions, charges and customers are protected."
    end
  end
end

%w[db:schema:load db:prepare].each do |name|
  Rake::Task[name].enhance do
    Rake::Task["db:tenancy:install"].invoke
  end
end
