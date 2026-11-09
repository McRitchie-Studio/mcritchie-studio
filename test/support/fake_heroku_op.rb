# frozen_string_literal: true

require "fileutils"
require "json"

# FakeHerokuOp — a stand-in `op` for the bin/heroku-token family. It answers
# `op read op://<vault>/<item>/credential` (the admin tier) and
# `op item get <item> --vault <vault> --format json` (a soul set) from a JSON map
# of "vault/item" => value, logs each call's argv, its OP_CACHE, and WHICH lane
# token it ran with as a LABEL (so a test can prove which lane token the read
# used and that the cache was bypassed), and prints nothing for an unknown
# reference, as a refused read does. It never writes a token's value: only the
# fixture tokens below have a label, and any other token logs as "other".
module FakeHerokuOp
  # Every variable a real shell on this Mac could carry into a child. A test
  # child gets each one explicitly unset, so a real token can never ride along
  # and the real `op` is never what answers.
  SCRUB = %w[
    HEROKU_API_KEY HEROKU_STUDIO_ADMIN_API_KEY HEROKU_STUDIO_AGENTS_API_KEY
    HEROKU_STUDIO_APPLICATIONS_API_KEY OP_SERVICE_ACCOUNT_TOKEN OP_ADMIN_SERVICE_ACCOUNT_TOKEN
    MCR_OP_VAULT_AGENT MCR_OP_VAULT_ADMIN MCR_OP_VAULT_APPLICATIONS
  ].to_h { |k| [k, nil] }.freeze

  # The fixture service-account tokens the tests issue. A logged token is one of
  # these or the word "other", never a value from a real shell.
  LABELS = %w[ops_agent ops_admin ops_fixture_agent ops_fixture_admin ops_steffon].freeze

  module_function

  # Writes the fake into +dir+ and returns its path.
  def install(dir, values)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "op-values.json"), JSON.generate(values))
    path = File.join(dir, "op")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      dir = #{dir.inspect}
      token = ENV["OP_SERVICE_ACCOUNT_TOKEN"].to_s
      label = token.empty? ? nil : (#{LABELS.inspect}.include?(token) ? token : "other")
      File.open(File.join(dir, "op.log"), "a") do |f|
        f.puts JSON.generate("argv" => ARGV, "cache" => ENV["OP_CACHE"], "token" => label)
      end
      values = JSON.parse(File.read(File.join(dir, "op-values.json")))
      if ARGV[0] == "read" && (m = ARGV[1].to_s.match(%r{\\Aop://([^/]+)/([^/]+)/credential\\z}))
        value = values["\#{m[1]}/\#{m[2]}"]
        if value
          puts value
          exit 0
        end
      end
      if ARGV[0, 2] == %w[item get] && (v = ARGV.index("--vault"))
        value = values["\#{ARGV[v + 1]}/\#{ARGV[2]}"]
        if value
          puts JSON.generate("fields" => [{ "label" => "credential", "value" => value }])
          exit 0
        end
      end
      warn "[ERROR] fake op: no such item"
      exit 1
    RUBY
    File.chmod(0o755, path)
    path
  end

  def calls(dir)
    path = File.join(dir, "op.log")
    File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end
end
