module Pff
  # What db/seeds/29_pff_grades.rb runs: import whatever PFF exports are on this
  # machine, and say on stderr what is absent.
  #
  # The repo ships none (Alex McRitchie's ruling, 2026-11-01), so absent is the normal
  # state of a clean checkout, and a seed that skips exits 0. $stderr.puts and not
  # Kernel#warn, which goes silent when $VERBOSE is nil.
  class SeedGrades
    SEED_DIR = "db/seeds/data/pff".freeze
    IMPORT_HINT = "An operator holding a licensed export runs bin/rails pff:import_dir DIR=path/to/dir SEASON=%s. " \
                  "Never commit it or host it: PFF's terms read as barring hosting.".freeze

    # Returns false after warning, so a caller's verdict can read it.
    def self.warn_unless_imported(season_slug, consequence:)
      return true if PffStat.where(season_slug: season_slug).exists?

      $stderr.puts "PFF: #{season_slug} has no imported PFF stats: #{consequence}. #{format(IMPORT_HINT, season_slug)}"
      false
    end

    def initialize(season_slug:, dir: Rails.root.join(SEED_DIR))
      @season_slug = season_slug
      @dir = dir
    end

    # Returns the number of files imported.
    def call
      paths = Dir.glob(File.join(@dir.to_s, "*.csv")).sort
      warn_absent(paths)

      paths.each do |path|
        type = stat_type(path)
        puts "\n--- PFF #{type} (#{File.basename(path)}) ---"
        ImportCsv.new(csv_path: path, season_slug: @season_slug, stat_type: type).call
      end
      paths.size
    end

    private

    def stat_type(path)
      File.basename(path, ".csv").downcase.gsub(/\s+/, "_")
    end

    def warn_absent(paths)
      expected = ImportCsv::POSITION_FILTER.keys
      absent = expected - paths.map { |path| stat_type(path) }
      return if absent.empty?

      if paths.empty?
        $stderr.puts "PFF: no CSVs in #{SEED_DIR}/, imported nothing. Active NFL athletes get a flat 50.0 placeholder, " \
                     "sub-grades stay empty, and team rankings rest on draft-tier prospect grades only. " \
                     "#{format(IMPORT_HINT, @season_slug)}"
      else
        $stderr.puts "PFF: #{absent.size} of #{expected.size} stat files absent from #{SEED_DIR}/ (#{absent.join(', ')}): " \
                     "athletes only those files cover get the flat 50.0 placeholder."
      end
    end
  end
end
