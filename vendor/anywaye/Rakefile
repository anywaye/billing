# frozen_string_literal: true

require "rake/testtask"

# The gate is `bin/prime`; these are the steps it runs, individually runnable.
#
# Coverage is not a task. It is started in test/test_helper.rb before the
# library is required and reported by an `after_run` hook, using Ruby's own
# `Coverage`, so `rake test` is the same command whether or not anyone is
# thinking about coverage and the gate costs no gem.

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
  t.verbose = false
end

desc "Rubocop, in parallel"
task :lint do
  sh "bundle exec rubocop --parallel"
end

desc "Audit the bundle for known security defects"
task :security do
  sh "bundle exec bundler-audit check --update"
end

namespace :db do
  desc "Create the test database if it is missing and load the outbox schema"
  task :prepare do
    require_relative "test/support/database"
    puts "database ready: #{TestSupport::Database.prepare!}"
  end

  desc "Drop and recreate the outbox schema"
  task :reset do
    require_relative "test/support/database"
    TestSupport::Database.reset_schema!
  end
end

desc "Everything bin/prime runs, in order"
task prime: [ "db:prepare", :lint, :security, :test ]

task default: :test
