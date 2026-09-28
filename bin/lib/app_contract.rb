# frozen_string_literal: true

require "yaml"
require "net/http"
require "open3"
require "uri"

# AppContract — checks, live and read-only, that an app already meets the
# standalone deploy contract (config/app_profiles.yml → contract) before
# bin/register-app writes its registry entry. Each check answers pass / fail
# with a remedy, so a refusal is a to-do list, not a mystery.
#
# Every probe that leaves the process (git, HTTP, heroku) goes through an
# injectable `probe`, so the unit tests drive each check without a network.
#
# Unit tests: test/lib/app_contract_test.rb
module AppContract
  Check = Struct.new(:name, :ok, :detail, :remedy, keyword_init: true)
  ORG = "McRitchie-Studio"
  RUNGS = %w[main accepted release].freeze

  # The default probe: real git / HTTP / heroku. Returns [stdout, success].
  class Probe
    def run(*argv)
      out, status = Open3.capture2e(*argv)
      [out, status.success?]
    rescue SystemCallError => e
      [e.message, false]
    end

    def http_status(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 15) do |http|
        http.get(uri.request_uri).code.to_i
      end
    rescue StandardError
      nil
    end

    def read(path) = File.exist?(path) ? File.read(path) : nil
  end

  module_function

  # The `test` job's single `bin/rails ...` step in .github/workflows/ci.yml, or
  # nil. That command, verbatim, is the registry's test_cmd.
  def ci_test_cmd(ci_yaml)
    jobs = (YAML.safe_load(ci_yaml.to_s, aliases: true) || {})["jobs"] || {}
    runs = Array(jobs.dig("test", "steps")).filter_map { |s| s.is_a?(Hash) ? s["run"].to_s.strip : nil }
    rails = runs.select { |r| r.start_with?("bin/rails") && !r.include?("\n") }
    rails.length == 1 ? rails.first : nil
  rescue Psych::Exception
    nil
  end

  # The studio-engine version in a Gemfile.lock, or nil when the app does not
  # consume the engine.
  def engine_version(lock) = lock.to_s[/^    studio-engine \(([0-9.]+)\)/, 1]

  def run(slug:, heroku_app:, smoke_url:, root:, probe: Probe.new)
    checks = []
    origin, = probe.run("git", "-C", root, "remote", "get-url", "origin")
    checks << Check.new(name: "repo", ok: origin.to_s.include?("#{ORG}/#{slug}"),
                        detail: origin.to_s.strip.empty? ? "no checkout at #{root}" : origin.strip,
                        remedy: "clone #{ORG}/#{slug} to #{root}")

    heads, = probe.run("git", "-C", root, "ls-remote", "--heads", "origin")
    missing = RUNGS.reject { |b| heads.to_s.match?(%r{refs/heads/#{b}$}) }
    checks << Check.new(name: "branches", ok: missing.empty?,
                        detail: missing.empty? ? "main, accepted, release" : "missing #{missing.join(', ')}",
                        remedy: "create them off main first: git -C <repo> push origin main:refs/heads/accepted main:refs/heads/release")

    test_cmd = ci_test_cmd(probe.read(File.join(root, ".github/workflows/ci.yml")))
    checks << Check.new(name: "ci test job", ok: !test_cmd.nil?, detail: test_cmd || "no single bin/rails step in jobs.test",
                        remedy: "give .github/workflows/ci.yml a `test` job with one `bin/rails ...` step")

    ignore = probe.read(File.join(root, ".gitignore")).to_s
    checks << Check.new(name: ".worktrees ignored", ok: ignore.match?(%r{^/?\.worktrees/?$}),
                        detail: ignore.match?(%r{^/?\.worktrees/?$}) ? "yes" : "no",
                        remedy: "add .worktrees/ to .gitignore")

    _info, heroku_ok = probe.run("heroku", "apps:info", "-a", heroku_app)
    checks << Check.new(name: "heroku app", ok: heroku_ok, detail: heroku_ok ? heroku_app : "#{heroku_app} not found",
                        remedy: "create the Heroku app on the company account")

    code = probe.http_status("#{smoke_url.to_s.chomp('/')}/up")
    checks << Check.new(name: "smoke /up", ok: code == 200, detail: "#{smoke_url.to_s.chomp('/')}/up -> #{code.inspect}",
                        remedy: "serve /up (rails/health#show) at the production host")

    gemfile = probe.read(File.join(root, "Gemfile")).to_s
    if gemfile.match?(/^\s*gem ["']pg["']/)
      procfile = probe.read(File.join(root, "Procfile")).to_s
      ok = procfile.match?(/^release:.*db:migrate/)
      checks << Check.new(name: "migrations", ok: ok, detail: ok ? "Procfile release phase runs db:migrate" : "no release phase migrate",
                          remedy: "add `release: bin/rails db:migrate` to the Procfile")
    end
    [checks, test_cmd]
  end
end
