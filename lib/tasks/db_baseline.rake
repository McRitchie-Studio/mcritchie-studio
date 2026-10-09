namespace :db do
  namespace :baseline do
    mark = lambda do |environments|
      environments.each do |environment|
        marked = DbBaseline.mark_environment!(environment, migrate_dir: Rails.root.join("db/migrate"))
        puts "db:baseline:mark recorded #{marked} baseline versions in #{environment}; no table changed" if marked.positive?
      end
    rescue DbBaseline::Error => e
      abort e.message
    end

    desc "Record the baseline's versions where the database already holds its tables (changes no table)"
    task(mark: "db:load_config") { mark.call([ Rails.env ]) }

    # db:prepare in development migrates the test database too, so both are marked first.
    task(mark_prepared: "db:load_config") { mark.call(DbBaseline.prepared_environments(Rails.env)) }

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
Rake::Task["db:migrate"].enhance([ "db:baseline:mark" ])
Rake::Task["db:prepare"].enhance([ "db:baseline:mark_prepared" ])

# db:test:prepare keeps a test database whose schema.rb is unchanged, so its ledger is marked after.
Rake::Task["db:test:prepare"].enhance do
  DbBaseline.mark_environment!("test", migrate_dir: Rails.root.join("db/migrate"))
end
