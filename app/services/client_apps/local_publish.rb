# frozen_string_literal: true

module ClientApps
  # `bin/client-bundle publish <sub> <dir> --local`: publish into THIS process's
  # database and storage (a desk's development database and storage/, Disk). It
  # runs through `bin/rails runner`, so it holds no credential of production's,
  # and it refuses to run in production: a production publish goes through the
  # hub's API (Api::V1::ClientBundlesController).
  module LocalPublish
    module_function

    def run(argv, out: $stdout)
      raise ArgumentError, "--local never runs in production; publish through the hub API" if Rails.env.production?

      sub, dir = argv
      raise ArgumentError, "usage: bin/client-bundle publish <sub> <dir> --local" if sub.to_s.empty? || dir.to_s.empty?

      app = App.find_by(slug: sub)
      raise ArgumentError, "no app #{sub} in the #{Rails.env} database" unless app

      bundle = ClientAppBundle.from_directory(dir)
      result = Publish.new(app: app, files: bundle.files, by: ENV["TASK_MASCOT"].presence || "local", source: "cli").call
      out.puts "published #{sub} #{result.version} (#{result.row.file_count} files, #{result.row.byte_size} bytes)"
      out.puts "previous: #{result.previous_version || 'none'}"
      out.puts "event: #{result.event ? "#{Publish::EVENT} on #{result.event.task_slug}" : 'none (no build task)'}"
      out.puts "url: #{result.url}"
      result
    end
  end
end
