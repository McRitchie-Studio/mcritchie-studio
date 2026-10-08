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

    desc "Read-only: report what the baseline finds in this database, or in a schema dump (AGAINST=path)"
    task check: "db:load_config" do
      if ENV["AGAINST"].present?
        found = DbBaseline.compare(File.read(ENV["AGAINST"]), root: Rails.root)
        puts "schema dump version: #{found.version}#{' (BEHIND the retired ledger; its remaining migrations are gone)' if found.behind}"
        puts "baseline tables the dump lacks (db:migrate creates them): #{found.absent.empty? ? 'none' : found.absent.join(', ')}"
        puts "tables short of baseline columns: #{found.short.empty? ? 'none' : found.short.join('; ')}"
        exit(found.short.any? || found.behind ? 1 : 0)
      end

      found = ActiveRecord::Base.connection_pool.with_connection do |connection|
        DbBaseline::Marker.new(connection: connection, migrate_dir: Rails.root.join("db/migrate")).report
      end
      puts "baseline versions recorded: #{found.recorded.size}"
      puts "present but not recorded (db:migrate records them): #{found.marked.size}"
      puts "to create (db:migrate runs them): #{found.pending.empty? ? 'none' : found.pending.join(', ')}"
      puts "tables short of baseline columns: #{found.short.empty? ? 'none' : found.short.join('; ')}"
      exit 1 if found.short.any?
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
