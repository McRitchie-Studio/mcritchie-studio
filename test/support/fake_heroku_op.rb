# frozen_string_literal: true

require "fileutils"
require "json"

# FakeHerokuOp — a stand-in `op` for the bin/heroku-token family. It answers
# `op read op://<vault>/<item>/credential` from a JSON map of "vault/item" =>
# value, logs each call's argv and its OP_CACHE and OP_SERVICE_ACCOUNT_TOKEN
# (so a test can prove which lane token the read used and that the cache was
# bypassed), and prints nothing for an unknown reference, as a refused read does.
module FakeHerokuOp
  # Every variable a real shell on this Mac could carry into a child. A test
  # child gets each one explicitly unset, so a real token can never ride along
  # and the real `op` is never what answers.
  SCRUB = %w[
    HEROKU_API_KEY HEROKU_STUDIO_ADMIN_API_KEY HEROKU_STUDIO_AGENTS_API_KEY
    HEROKU_STUDIO_APPLICATIONS_API_KEY OP_SERVICE_ACCOUNT_TOKEN OP_ADMIN_SERVICE_ACCOUNT_TOKEN
    MCR_OP_VAULT_AGENT MCR_OP_VAULT_ADMIN MCR_OP_VAULT_APPLICATIONS
  ].to_h { |k| [k, nil] }.freeze

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
      File.open(File.join(dir, "op.log"), "a") do |f|
        f.puts JSON.generate("argv" => ARGV, "cache" => ENV["OP_CACHE"], "token" => ENV["OP_SERVICE_ACCOUNT_TOKEN"])
      end
      values = JSON.parse(File.read(File.join(dir, "op-values.json")))
      if ARGV[0] == "read" && (m = ARGV[1].to_s.match(%r{\\Aop://([^/]+)/([^/]+)/credential\\z}))
        value = values["\#{m[1]}/\#{m[2]}"]
        if value
          puts value
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
