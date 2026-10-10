# frozen_string_literal: true

require "yaml"
require "net/http"
require "open3"
require "uri"
# The release sweep's own guard, reused so the contract can never pass a workflow
# bin/release prepare refuses (Carl, review of contract-checks-ci-triggers). It does
# no I/O and bin/release.rb already loads it standalone.
require_relative "../../app/models/release/accepted_certification"
require_relative "ci_suite_workflow"

# AppContract — checks, live and read-only, that an app already meets the
# standalone deploy contract (config/app_profiles.yml → contract) before
# bin/register-app writes its registry entry. Each check answers pass / fail
# with a remedy, so a refusal is a to-do list, not a mystery.
#
# Every probe that leaves the process (git, HTTP, heroku) goes through an
# injectable `probe`, so the unit tests drive each check without a network.
#
# Unit tests: test/lib/app_profile_test.rb (the AppContract section)
module AppContract
  Check = Struct.new(:name, :ok, :detail, :remedy, keyword_init: true)
  ORG = "McRitchie-Studio"
  RUNGS = %w[main accepted release].freeze
  # The branch a release carries: feature PRs land on accepted and the sweep
  # promotes it, so that is the tree the contract must hold for.
  REF = "origin/accepted"

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

    # A file as it stands at a ref, or nil. The contract judges the branch a
    # release ships (REF), not whatever the primary checkout has on disk: a
    # primary sitting on main would otherwise hide a fix that already landed on
    # accepted (measured 2026-09-28 on moms-app's .gitignore).
    def read_at(root, ref, relpath)
      out, ok = run("git", "-C", root, "show", "#{ref}:#{relpath}")
      ok ? out : nil
    end
  end

  module_function

  # The suite command of .github/workflows/ci.yml, or nil. That command, verbatim,
  # is the registry's test_cmd. Two shapes carry one: a `test` job with a single
  # `bin/rails ...` step, or a job that calls the hub's reusable-ci.yml, whose
  # suite command is its `system-command` input (`suite_yaml` supplies the default).
  def ci_test_cmd(ci_yaml, suite_yaml: nil)
    jobs = (YAML.safe_load(ci_yaml.to_s, aliases: true) || {})["jobs"] || {}
    runs = Array(jobs.dig("test", "steps")).filter_map { |s| s.is_a?(Hash) ? s["run"].to_s.strip : nil }
    runs = [CiSuiteWorkflow.caller_suite_command(ci_yaml, suite_yaml: suite_yaml).to_s] if runs.empty?
    rails = runs.select { |r| r.start_with?("bin/rails") && !r.include?("\n") }
    rails.length == 1 ? rails.first : nil
  rescue Psych::Exception
    nil
  end

  # The hub's reusable-ci.yml as production has it, read from the hub checkout beside
  # `root`. Only a caller that passes no `system-command` needs it; nil otherwise.
  def suite_text(ci_yaml, root, probe)
    return nil unless CiSuiteWorkflow.caller_job(ci_yaml)

    hub = File.join(File.dirname(root), CiSuiteWorkflow::HUB_NWO.split("/").last)
    probe.read_at(hub, "origin/main", CiSuiteWorkflow::SUITE_PATH)
  rescue Psych::Exception
    nil
  end

  # Whether the hub's app catalog (config/apps.yml) gives this slug a glyph. The
  # board draws a badge per registry repo from ApplicationHelper::APP_EMOJIS,
  # which derives from the catalog, and test/helpers/application_helper_test.rb
  # fails CI for a repo with none.
  def glyph_check(catalog_text, slug)
    catalog = YAML.safe_load(catalog_text.to_s) || {}
    rows = Array(catalog["apps"]) + Array(catalog["libraries"])
    row = rows.find { |r| r.is_a?(Hash) && r["slug"] == slug }
    ok = !!(row && row["emoji"].to_s.strip != "")
    Check.new(name: "hub badge glyph", ok: ok, detail: ok ? "#{row['emoji']} in config/apps.yml" : "no config/apps.yml record",
              remedy: "add a #{slug} record to config/apps.yml in the hub, in the registration task, then run test/lib/app_registry_test.rb")
  rescue Psych::Exception
    Check.new(name: "hub badge glyph", ok: false, detail: "config/apps.yml does not parse", remedy: "fix config/apps.yml")
  end

  # Whether the hub's config/satellites.yml gives this slug a port block. Desks
  # take their ports from it, so bin/agent-worktree refuses an app without a
  # row ("unknown app"); measured 2026-09-29, when moms-app registered on this
  # profile without one and every desk had to be cut by hand.
  def desk_ports_check(satellites_text, slug)
    rows = (YAML.safe_load(satellites_text.to_s) || {}).fetch("satellites", [])
    row = rows.find { |r| r["slug"] == slug }
    ok = row && row["port"].is_a?(Integer)
    Check.new(name: "desk ports", ok: !!ok, detail: ok ? "#{row['port']}-#{row['port'] + 99} (#{row['status']})" : "no config/satellites.yml row",
              remedy: "reserve a block in the hub, in the registration task: bin/register-satellite --list, then --slug #{slug} --port <next open> --status reserved --write")
  rescue Psych::Exception
    Check.new(name: "desk ports", ok: false, detail: "config/satellites.yml does not parse", remedy: "fix config/satellites.yml")
  end

  # Every workflow file at REF, as { path => yaml_text }: the shape
  # Release::AcceptedCertification.certified? reads, since the sweep matches the
  # suite workflow by NAME across all of them, not by the filename ci.yml.
  def workflow_files(root, probe)
    listing, ok = probe.run("git", "-C", root, "ls-tree", "--name-only", REF, ".github/workflows/")
    return {} unless ok

    listing.lines.map(&:strip).select { |p| p.end_with?(".yml", ".yaml") }
           .to_h { |p| [p, probe.read_at(root, REF, p).to_s] }
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

    # A failed fetch would leave every file check below reading a STALE
    # origin/accepted and passing or failing on old news, so it is a check.
    _fetch_out, fetched = probe.run("git", "-C", root, "fetch", "origin", "--quiet")
    checks << Check.new(name: "fetch", ok: fetched, detail: fetched ? "origin fetched" : "git fetch origin failed",
                        remedy: "fix the checkout's remote or GitHub auth, then re-run (file checks read #{REF})")
    heads, = probe.run("git", "-C", root, "ls-remote", "--heads", "origin")
    missing = RUNGS.reject { |b| heads.to_s.match?(%r{refs/heads/#{b}$}) }
    checks << Check.new(name: "branches", ok: missing.empty?,
                        detail: missing.empty? ? "main, accepted, release" : "missing #{missing.join(', ')}",
                        remedy: "create them off main first: git -C <repo> push origin main:refs/heads/accepted main:refs/heads/release")

    # bin/release prepare refuses to promote a rung CI never builds
    # (refuse_blind_accepted!): measured 2026-09-28, when moms-app passed every
    # other check here and was then refused because its CI ran on main only. The
    # decision is Release::AcceptedCertification's, over EVERY workflow file, so
    # the name match, branches-ignore and path filters all agree with the sweep.
    workflows = workflow_files(root, probe)
    ci_yaml = workflows[".github/workflows/ci.yml"]
    test_cmd = ci_test_cmd(ci_yaml, suite_yaml: suite_text(ci_yaml, root, probe))
    blind = %w[accepted release].reject do |rung|
      Release::AcceptedCertification.certified?(workflows, Release::AcceptedCertification::DEFAULT_SUITE_WORKFLOW, rung)
    end
    checks << Check.new(name: "ci on release rungs", ok: blind.empty?,
                        detail: blind.empty? ? "workflow \"CI\" builds pushes to accepted and release" : "no workflow named \"CI\" builds pushes to #{blind.join(', ')}",
                        remedy: "name the suite workflow `CI`, give it `push: branches: [ main, release, accepted ]` with no path filter or branches-ignore, and merge it to accepted")
    checks << Check.new(name: "ci test job", ok: !test_cmd.nil?, detail: test_cmd || "no single bin/rails step in jobs.test, and no reusable-ci.yml call with a bin/rails system-command",
                        remedy: "give .github/workflows/ci.yml a `test` job with one `bin/rails ...` step, or call the hub's reusable-ci.yml with a `system-command`")

    ignore = probe.read_at(root, REF, ".gitignore").to_s
    checks << Check.new(name: ".worktrees ignored", ok: ignore.match?(%r{^/?\.worktrees/?$}),
                        detail: ignore.match?(%r{^/?\.worktrees/?$}) ? "yes" : "no",
                        remedy: "add .worktrees/ to .gitignore")

    _info, heroku_ok = probe.run("heroku", "apps:info", "-a", heroku_app)
    checks << Check.new(name: "heroku app", ok: heroku_ok, detail: heroku_ok ? heroku_app : "#{heroku_app} not found",
                        remedy: "create the Heroku app on the company account")

    code = probe.http_status("#{smoke_url.to_s.chomp('/')}/up")
    checks << Check.new(name: "smoke /up", ok: code == 200, detail: "#{smoke_url.to_s.chomp('/')}/up -> #{code.inspect}",
                        remedy: "serve /up (rails/health#show) at the production host")

    gemfile = probe.read_at(root, REF, "Gemfile").to_s
    if gemfile.match?(/^\s*gem ["']pg["']/)
      procfile = probe.read_at(root, REF, "Procfile").to_s
      ok = procfile.match?(/^release:.*db:migrate/)
      checks << Check.new(name: "migrations", ok: ok, detail: ok ? "Procfile release phase runs db:migrate" : "no release phase migrate",
                          remedy: "add `release: bin/rails db:migrate` to the Procfile")
    end
    [checks, test_cmd]
  end
end
