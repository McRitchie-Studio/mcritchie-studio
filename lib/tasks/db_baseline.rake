namespace :db do
  namespace :baseline do
    desc "Record the baseline's versions where the database already holds its tables (changes no table)"
    task mark: "db:load_config" do
      pool = ActiveRecord::Base.connection_pool
      result = pool.with_connection do |connection|
        DbBaseline::Marker.new(connection: connection, migrate_dir: Rails.root.join("db/migrate")).mark!
      end
      puts "db:baseline:mark recorded #{result.marked.size} baseline versions; no table changed" if result.marked.any?
    rescue ActiveRecord::NoDatabaseError
      # No database yet: db:prepare creates it and loads the schema.
    rescue DbBaseline::Error => e
      abort e.message
    end

    desc "Bring a database that stopped partway through the retired migrations to their head, then migrate"
    task catch_up: "db:load_config" do
      DbBaseline::CatchUp.new(root: Rails.root, pool: ActiveRecord::Base.connection_pool).run!
      Rake::Task["db:migrate"].invoke
    rescue DbBaseline::Error => e
      abort e.message
    end
  end
end

# The release phase runs db:migrate and desks run db:prepare, so the mark runs ahead of both.
%w[db:migrate db:prepare].each { |name| Rake::Task[name].enhance(["db:baseline:mark"]) }

# db:test:prepare keeps a test database whose schema.rb is unchanged, so its ledger is marked after.
Rake::Task["db:test:prepare"].enhance do
  ActiveRecord::Tasks::DatabaseTasks.with_temporary_pool_for_each(env: "test") do |pool|
    pool.with_connection do |connection|
      DbBaseline::Marker.new(connection: connection, migrate_dir: Rails.root.join("db/migrate")).mark!
    end
  end
end
