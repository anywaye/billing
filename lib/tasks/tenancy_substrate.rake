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
