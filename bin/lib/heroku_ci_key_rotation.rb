# frozen_string_literal: true

# HerokuCiKeyRotation — rotate the Heroku key GitHub Actions deploys with
# (the HEROKU_API_KEY secret on the `qa` and `production` environments of
# McRitchie-Studio/mcritchie-studio), end to end and unattended.
#
# WHY IT CAN BE UNATTENDED NOW. Until 2026-09-26 the GitHub half was an operator
# step: the agent App had no secrets grant (credential-rotation.md §1.2). The ship
# App was renamed mcritchie-deployer -> mcritchie-admin that day and granted
# Environments + Secrets read/write, so the admin lane can write the secret itself.
#
# THE ORDER, and why it is this order (credential-rotation.md Phases 4-6):
#   preflight  read-only: both admin credentials present, the admin Heroku key is
#              alex@mcritchie.studio, the vault's authorization-id really is the
#              authorization behind the vault's key (compared by digest), both
#              environment secrets exist, and no deploy is in flight.
#   mint       a NEW authorization, same scope as the old one, with the ADMIN key.
#              The agents key is refused by Heroku here (403, observed 2026-09-26).
#   store      1Password FIRST (credential + authorization-id), read back by digest.
#   set        the environment secret in qa, then production.
#   prove      dispatch qa-deploy.yml and prod-deploy.yml at the SHA each app is
#              already running: a no-op push that only succeeds if Heroku accepts
#              the new key. Conclusion must be `success`.
#   revoke     the OLD authorization — only after BOTH proofs passed — and prove
#              the old key is dead.
#
# ROLLBACK. A failure after the mint restores the old value everywhere this run
# wrote it (secrets, then vault) and revokes the NEW authorization, leaving the
# world as it found it. The old authorization is never revoked on a failed run.
#
# NEVER PRINT A SECRET. Keys ride in HTTP headers, child environments and stdin —
# never argv, never output. Every message that quotes a child's output passes
# through #redact first. Comparisons are by digest, and a digest of nothing is
# refused rather than compared (credential-rotation.md "Compare by digest").

require "digest"
require "json"
require "net/http"
require "open3"
require "time"
require "uri"

module HerokuCiKeyRotation
  REPO = "McRitchie-Studio/mcritchie-studio"
  SECRET = "HEROKU_API_KEY"
  ACCOUNT = "alex@mcritchie.studio"
  VAULT = "studio-applications"
  ITEM = "heroku.studio.applications"
  KEY_FIELD = "credential"
  AUTH_ID_FIELD = "authorization-id"
  GH_APP_ITEM = "github.mcritchie-admin"

  # qa first: a broken proof there stops the run before production is touched.
  TARGETS = [
    { env: "qa", app: "mcritchie-studio-qa", workflow: "qa-deploy.yml" },
    { env: "production", app: "mcritchie-studio", workflow: "prod-deploy.yml" }
  ].freeze

  STEPS = %w[mint store set prove revoke].freeze

  class Abort < StandardError; end

  module_function

  # A 16-hex prefix of sha256, refusing an empty value: two empty reads would
  # otherwise MATCH and certify a wipe.
  def digest(value)
    v = value.to_s
    raise Abort, "EMPTY — refusing to digest nothing; this comparison is void" if v.empty?

    Digest::SHA256.hexdigest(v)[0, 16]
  end

  def same?(a, b) = digest(a) == digest(b)

  def redact(text, secrets)
    secrets.compact.map(&:to_s).reject(&:empty?).reduce(text.to_s) { |t, s| t.gsub(s, "[REDACTED]") }
  end

  # ── Heroku Platform API ────────────────────────────────────────────────────
  # Net::HTTP, not the `heroku` CLI: the key goes in a header, and the slug read
  # (which SHA an app is running) has no CLI command.
  class HerokuApi
    def initialize(base: ENV.fetch("ROTATE_HEROKU_CI_KEY_API_BASE", "https://api.heroku.com"))
      @base = URI(base)
    end

    def account_email(key) = request(:get, "/account", key).fetch("email")

    def authorization(key, id)
      body = request(:get, "/oauth/authorizations/#{id}", key)
      { id: body.fetch("id"), description: body["description"].to_s,
        scope: Array(body["scope"]), token: body.dig("access_token", "token").to_s }
    end

    def create_authorization(key, description:, scope:)
      body = request(:post, "/oauth/authorizations", key, { description: description, scope: scope })
      { id: body.fetch("id"), token: body.dig("access_token", "token").to_s }
    end

    def revoke_authorization(key, id) = request(:delete, "/oauth/authorizations/#{id}", key)

    # The commit the app is RUNNING: its current release's slug, not the newest
    # "Deploy <sha>" line — a rollback or a config-only release breaks that proxy.
    def live_commit(key, app)
      releases = request(:get, "/apps/#{app}/releases", key, nil, "Range" => "version ..; order=desc, max=20")
      current = Array(releases).find { |r| r["current"] } ||
                raise(Abort, "#{app}: no current release in the 20 newest")
      slug_id = current.dig("slug", "id") || raise(Abort, "#{app}: current release v#{current['version']} has no slug")
      commit = request(:get, "/apps/#{app}/slugs/#{slug_id}", key)["commit"].to_s
      raise Abort, "#{app}: slug #{slug_id} records no commit" unless commit.match?(/\A\h{40}\z/)

      commit
    end

    # true when the key authenticates, false on a 401; anything else raises.
    def key_live?(key)
      account_email(key)
      true
    rescue Abort => e
      return false if e.message.include?("HTTP 401")

      raise
    end

    private

    def request(verb, path, key, body = nil, headers = {})
      raise Abort, "refusing a Heroku call with an empty key" if key.to_s.empty?

      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(verb)
      req = klass.new(path)
      req["Accept"] = "application/vnd.heroku+json; version=3"
      req["Authorization"] = "Bearer #{key}"
      req["Content-Type"] = "application/json"
      # identity, explicitly: a Range-paged answer (the releases list) carries a
      # Content-Range header, and Net::HTTP then skips gunzipping the body.
      req["Accept-Encoding"] = "identity"
      headers.each { |k, v| req[k] = v }
      req.body = JSON.generate(body) if body
      res = Net::HTTP.start(@base.host, @base.port, use_ssl: @base.scheme == "https",
                                                    open_timeout: 15, read_timeout: 60) { |http| http.request(req) }
      unless res.code.to_i.between?(200, 299)
        # The body of an error is Heroku's own message; it never echoes the key.
        msg = (JSON.parse(res.body.to_s)["message"] rescue res.body.to_s[0, 200]) # rubocop:disable Style/RescueModifier
        raise Abort, "Heroku #{verb.upcase} #{path}: HTTP #{res.code} #{msg}"
      end
      res.body.to_s.empty? ? {} : JSON.parse(res.body)
    end
  end

  # ── 1Password, via `op` on the admin lane ──────────────────────────────────
  class Vault
    def initialize(op_token:, shell:, bin: ENV.fetch("ROTATE_HEROKU_CI_KEY_OP_BIN", "op"))
      @env = { "OP_SERVICE_ACCOUNT_TOKEN" => op_token }
      @shell = shell
      @bin = bin
    end

    def read(field)
      out = @shell.call([@bin, "read", "op://#{VAULT}/#{ITEM}/#{field}"], env: @env)
      out.chomp
    end

    # The value rides STDIN as the item's JSON (`op item edit` reads a piped
    # template), never argv — an assignment statement is visible to `ps`.
    def write(fields)
      item = JSON.parse(@shell.call([@bin, "item", "get", ITEM, "--vault", VAULT, "--format", "json"], env: @env))
      fields.each do |label, value|
        field = Array(item["fields"]).find { |f| f["label"] == label } ||
                raise(Abort, "1Password item #{ITEM} has no `#{label}` field")
        field["value"] = value
      end
      @shell.call([@bin, "item", "edit", ITEM, "--vault", VAULT], env: @env, stdin: JSON.generate(item))
      nil
    end
  end

  # ── GitHub, via `gh` as the mcritchie-admin App ────────────────────────────
  class GitHub
    def initialize(token:, shell:, bin: ENV.fetch("ROTATE_HEROKU_CI_KEY_GH_BIN", "gh"))
      @env = { "GH_TOKEN" => token }
      @shell = shell
      @bin = bin
    end

    def secret_updated_at(env)
      out = @shell.call([@bin, "api", "repos/#{REPO}/environments/#{env}/secrets/#{SECRET}"], env: @env)
      JSON.parse(out).fetch("updated_at")
    end

    # Value on stdin: `gh secret set` reads the body there when --body is absent.
    def set_secret(env, value)
      @shell.call([@bin, "secret", "set", SECRET, "--env", env, "--repo", REPO], env: @env, stdin: value)
      nil
    end

    def runs(workflow)
      out = @shell.call([@bin, "run", "list", "--repo", REPO, "--workflow", workflow, "--limit", "20",
                         "--json", "databaseId,status,conclusion,event"], env: @env)
      JSON.parse(out)
    end

    def dispatch(workflow, sha)
      @shell.call([@bin, "workflow", "run", workflow, "--repo", REPO, "-f", "sha=#{sha}"], env: @env)
      nil
    end

    def run(id)
      JSON.parse(@shell.call([@bin, "run", "view", id.to_s, "--repo", REPO, "--json", "status,conclusion"], env: @env))
    end
  end

  # Runs a child and returns stdout; raises Abort (with redacted stderr) on failure.
  class Shell
    def initialize(redactor)
      @redactor = redactor
    end

    def call(argv, env: {}, stdin: nil)
      out, err, status = Open3.capture3(env, *argv, stdin_data: stdin.to_s)
      return out if status.success?

      raise Abort, @redactor.call("`#{argv.first(3).join(' ')}` exited #{status.exitstatus}: #{err.strip[0, 400]}")
    end
  end

  class Runner
    attr_reader :log

    # `secrets` is SHARED with the Shell's redactor, so a value this runner learns
    # (the old key, the new one) is scrubbed from every child's error text too.
    def initialize(heroku:, vault:, github:, admin_key:, secrets: [], out: $stdout, poll_seconds: 10,
                   run_timeout: 1800, clock: -> { Time.now.utc }, sleeper: ->(s) { sleep s })
      @heroku = heroku
      @vault = vault
      @github = github
      @admin_key = admin_key
      @out = out
      @poll = poll_seconds
      @run_timeout = run_timeout
      @clock = clock
      @sleeper = sleeper
      @secrets = secrets
      @secrets << admin_key
      @written = []
    end

    def redact(text) = HerokuCiKeyRotation.redact(text, @secrets)

    def call(dry_run:)
      plan = preflight
      print_plan(plan)
      return plan if dry_run

      new_auth = mint(plan)
      begin
        store(new_auth)
        set(new_auth)
        prove(plan)
      rescue Abort => e
        say "FAILED after the mint: #{redact(e.message)}"
        rollback(plan, new_auth)
        raise Abort, "rotation rolled back; the old authorization #{plan[:old_id]} was NOT revoked"
      end
      revoke(plan, new_auth)
      receipt(plan, new_auth)
      plan
    end

    private

    def say(line) = @out.puts(line)

    def preflight
      say "== preflight (read-only)"
      email = @heroku.account_email(@admin_key)
      raise Abort, "the admin Heroku key authenticates as #{email}, expected #{ACCOUNT}" unless email == ACCOUNT

      say "  admin Heroku key: #{ACCOUNT}"
      old_key = @vault.read(KEY_FIELD)
      old_id = @vault.read(AUTH_ID_FIELD)
      @secrets << old_key
      raise Abort, "#{ITEM}/#{KEY_FIELD} read back EMPTY" if old_key.empty?
      raise Abort, "#{ITEM}/#{AUTH_ID_FIELD} read back EMPTY" if old_id.empty?

      old = @heroku.authorization(@admin_key, old_id)
      @secrets << old[:token]
      unless HerokuCiKeyRotation.same?(old[:token], old_key)
        raise Abort, "authorization #{old_id} does not hold the key in #{VAULT}/#{ITEM} (digests differ) — " \
                     "revoking it would kill the wrong key; fix #{AUTH_ID_FIELD} first"
      end
      say "  old authorization #{old_id} (#{old[:description]}), scope #{old[:scope].join(',')}: " \
          "matches the vault key by digest"

      targets = TARGETS.map do |t|
        updated = @github.secret_updated_at(t[:env])
        busy = in_flight(t[:workflow])
        raise Abort, "#{t[:workflow]} has #{busy} run(s) in flight — a no-op deploy queued behind a real one " \
                     "would roll it back; wait for it to finish" if busy.positive?

        sha = @heroku.live_commit(@admin_key, t[:app])
        say "  #{t[:env]}: secret #{SECRET} present (updated #{updated}); #{t[:app]} runs #{sha}; " \
            "#{t[:workflow]} idle"
        t.merge(sha: sha)
      end
      { old_id: old_id, old_key: old_key, scope: old[:scope], targets: targets }
    end

    def print_plan(plan)
      say "== plan"
      say "  1. mint    a new Heroku authorization on #{ACCOUNT} (scope #{plan[:scope].join(',')}) with the admin key"
      say "  2. store   it in op://#{VAULT}/#{ITEM} (#{KEY_FIELD} + #{AUTH_ID_FIELD}); read back by digest"
      plan[:targets].each_with_index do |t, i|
        say "  3.#{i + 1} set     #{SECRET} on environment #{t[:env]} as #{GH_APP_ITEM}"
      end
      plan[:targets].each_with_index do |t, i|
        say "  4.#{i + 1} prove   dispatch #{t[:workflow]} sha=#{t[:sha]} (the SHA #{t[:app]} already runs); " \
            "require conclusion success"
      end
      say "  5. revoke  the old authorization #{plan[:old_id]} once both proofs pass; prove the old key is dead"
    end

    def mint(plan)
      say "== 1. mint"
      desc = "#{ITEM} (rotated #{@clock.call.strftime('%Y-%m-%d')} by bin/rotate-heroku-ci-key)"
      auth = @heroku.create_authorization(@admin_key, description: desc, scope: plan[:scope])
      @secrets << auth[:token]
      raise Abort, "Heroku minted an EMPTY token" if auth[:token].empty?
      raise Abort, "the new key does not authenticate as #{ACCOUNT}" unless @heroku.account_email(auth[:token]) == ACCOUNT

      say "  minted authorization #{auth[:id]}; it authenticates as #{ACCOUNT}"
      auth
    end

    def store(auth)
      say "== 2. store"
      @vault.write(KEY_FIELD => auth[:token], AUTH_ID_FIELD => auth[:id])
      @written << :vault
      raise Abort, "vault read-back does not match the minted key" unless HerokuCiKeyRotation.same?(@vault.read(KEY_FIELD), auth[:token])
      raise Abort, "vault #{AUTH_ID_FIELD} read-back is not #{auth[:id]}" unless @vault.read(AUTH_ID_FIELD) == auth[:id]

      say "  op://#{VAULT}/#{ITEM}: #{KEY_FIELD} MATCH by digest, #{AUTH_ID_FIELD} = #{auth[:id]}"
    end

    def set(auth)
      say "== 3. set"
      TARGETS.each do |t|
        before = @clock.call
        @github.set_secret(t[:env], auth[:token])
        @written << t[:env]
        updated = Time.parse(@github.secret_updated_at(t[:env]))
        raise Abort, "#{t[:env]}: #{SECRET} updated_at #{updated.iso8601} did not move" if updated < before - 120

        say "  #{t[:env]}: #{SECRET} set (updated #{updated.iso8601})"
      end
    end

    def prove(plan)
      say "== 4. prove"
      plan[:targets].each do |t|
        busy = in_flight(t[:workflow])
        raise Abort, "#{t[:workflow]} gained #{busy} in-flight run(s) since preflight; not dispatching" if busy.positive?

        live = @heroku.live_commit(@admin_key, t[:app])
        raise Abort, "#{t[:app]} moved from #{t[:sha]} to #{live} since preflight; not dispatching" unless live == t[:sha]

        baseline = latest_run_id(t[:workflow])
        @github.dispatch(t[:workflow], t[:sha])
        id = wait_for_new_run(t[:workflow], baseline)
        result = wait_for_completion(id)
        unless result["conclusion"] == "success"
          raise Abort, "#{t[:workflow]} run #{id} concluded #{result['conclusion'].inspect}, not success"
        end

        say "  #{t[:workflow]} run #{id}: success at #{t[:sha]} (the new key deployed to #{t[:app]})"
      end
    end

    def revoke(plan, auth)
      say "== 5. revoke"
      raise Abort, "refusing to revoke: old and new authorization ids are the same" if plan[:old_id] == auth[:id]

      @heroku.revoke_authorization(@admin_key, plan[:old_id])
      raise Abort, "the old key still authenticates after revoking #{plan[:old_id]}" if @heroku.key_live?(plan[:old_key])

      say "  revoked #{plan[:old_id]}; the old key now answers 401"
    end

    # A store that could not be restored still HOLDS the new key: revoke the new
    # authorization only when every restore succeeded, or a deploy secret dies.
    def rollback(plan, auth)
      say "== rollback"
      stranded = []
      (@written & TARGETS.map { |t| t[:env] }).each do |env|
        @github.set_secret(env, plan[:old_key])
        say "  #{env}: #{SECRET} restored to the old key"
      rescue Abort => e
        stranded << env
        say "  #{env}: RESTORE FAILED — #{redact(e.message)}"
      end
      if @written.include?(:vault)
        begin
          @vault.write(KEY_FIELD => plan[:old_key], AUTH_ID_FIELD => plan[:old_id])
          say "  op://#{VAULT}/#{ITEM}: restored to authorization #{plan[:old_id]}"
        rescue Abort => e
          stranded << :vault
          say "  vault RESTORE FAILED — #{redact(e.message)} (1Password keeps item history)"
        end
      end
      unless stranded.empty?
        return say "  NOT revoking the new authorization #{auth[:id]}: #{stranded.join(', ')} still hold it"
      end

      @heroku.revoke_authorization(@admin_key, auth[:id])
      say "  revoked the new authorization #{auth[:id]}"
    rescue Abort => e
      say "  could not revoke the new authorization #{auth[:id]}: #{redact(e.message)} — revoke it by hand"
    end

    def receipt(plan, auth)
      say "== receipt"
      say "  #{ITEM}: authorization #{plan[:old_id]} -> #{auth[:id]}; #{SECRET} rotated on " \
          "#{TARGETS.map { |t| t[:env] }.join(' and ')}; old key revoked."
      say "  ~/.zprofile.admin: HEROKU_STUDIO_APPLICATIONS_API_KEY still holds the REVOKED key. Refresh it from " \
          "op://#{VAULT}/#{ITEM}/#{KEY_FIELD} (never paste the value into chat)."
    end

    def in_flight(workflow) = @github.runs(workflow).count { |r| r["status"] != "completed" }

    def latest_run_id(workflow) = @github.runs(workflow).map { |r| r["databaseId"].to_i }.max || 0

    def wait_for_new_run(workflow, baseline)
      deadline = @clock.call + 180
      loop do
        run = @github.runs(workflow).find { |r| r["databaseId"].to_i > baseline && r["event"] == "workflow_dispatch" }
        return run["databaseId"] if run
        raise Abort, "#{workflow}: no dispatched run appeared within 3 minutes" if @clock.call > deadline

        @sleeper.call(@poll)
      end
    end

    def wait_for_completion(id)
      deadline = @clock.call + @run_timeout
      loop do
        result = @github.run(id)
        return result if result["status"] == "completed"
        raise Abort, "run #{id} did not complete within #{@run_timeout}s" if @clock.call > deadline

        @sleeper.call(@poll)
      end
    end
  end
end
