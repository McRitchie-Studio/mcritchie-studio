# frozen_string_literal: true

# [integration] bin/rotate-heroku-ci-key end to end, across its real I/O
# boundaries: the Heroku Platform API over HTTP (a loopback fake), and `op`, `gh`
# and bin/gh-token as child processes (fakes on the script's declared seams).
# Every fake LOGS what it was asked, so "a dry run mutates nothing" and "no secret
# rides argv" are asserted by receipt.

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"
require_relative "../support/session_env"

class RotateHerokuCiKeyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "rotate-heroku-ci-key")

  ADMIN_KEY = "HRKU-fake-admin-key-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  OLD_KEY = "HRKU-fake-old-ci-key-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  NEW_KEY = "HRKU-fake-new-ci-key-cccccccccccccccccccccccccccccccccccccccccccc"
  OP_TOKEN = "ops_fake-admin-service-account-token"
  GH_TOKEN = "ghs_fakeAdminInstallationToken0000000000"
  OLD_ID = "11111111-1111-1111-1111-111111111111"
  NEW_ID = "22222222-2222-2222-2222-222222222222"
  SHA = "0123456789abcdef0123456789abcdef01234567"
  SECRETS = [ADMIN_KEY, OLD_KEY, NEW_KEY, OP_TOKEN, GH_TOKEN].freeze

  def setup
    @dir = Dir.mktmpdir("rotate-heroku-ci-key")
    @requests = []
    @revoked = []
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
    write_fakes
  end

  def teardown
    @server&.close
    @thread&.kill
    FileUtils.rm_rf(@dir)
  end

  def test_dry_run_prints_the_plan_in_order_and_mutates_nothing
    out, err, status = run_script("--dry-run")

    assert status.success?, "#{out}\n#{err}"
    plan = out[/== plan.*/m].to_s
    positions = %w[mint store set prove revoke].map { |step| plan.index(/^\s+[\d.]+ #{step}\b/) }
    refute_includes positions, nil, plan
    assert_equal positions.sort, positions, "the plan must read mint, store, set, prove, revoke"
    assert_includes out, "DRY RUN"

    verbs = @requests.map(&:first).uniq
    assert_equal ["GET"], verbs, "a dry run may only READ Heroku: #{@requests.inspect}"
    calls = log("op") + log("gh")
    %w[item\ edit secret\ set workflow\ run].each do |mutation|
      refute_includes calls, mutation, "a dry run must never #{mutation}"
    end
    assert_no_secret_leaked(out, err)
  end

  def test_a_full_run_crosses_every_boundary_in_order
    out, err, status = run_script

    assert status.success?, "#{out}\n#{err}"
    assert_includes @requests, ["POST", "/oauth/authorizations"]
    assert_equal [OLD_ID], @revoked, "only the OLD authorization is revoked, and only once"
    gh = log("gh")
    assert_operator gh.index("secret set HEROKU_API_KEY --env qa"), :<, gh.index("workflow run qa-deploy.yml")
    assert_operator gh.index("workflow run qa-deploy.yml"), :<, gh.index("workflow run prod-deploy.yml")
    assert_includes gh, "-f sha=#{SHA}"
    assert_includes log("op"), "item edit heroku.studio.applications --vault studio-applications"
    assert_equal 2, File.read(File.join(@dir, "secret-stdin.log")).scan(NEW_KEY).size,
                 "the new key reaches both environments on STDIN"
    assert_equal NEW_KEY, JSON.parse(File.read(File.join(@dir, "item.json")))["fields"]
                                 .find { |f| f["label"] == "credential" }["value"]
    assert_no_secret_leaked(out, err)
  end

  def test_without_the_admin_lane_it_does_nothing
    out, err, status = run_script("--dry-run", env: { "HEROKU_STUDIO_ADMIN_API_KEY" => nil })

    assert_equal 1, status.exitstatus, "#{out}\n#{err}"
    assert_includes err, "source ~/.zprofile.admin"
    assert_empty @requests
    assert_empty log("op")
  end

  private

  def assert_no_secret_leaked(out, err)
    argv = log("op") + log("gh") + log("gh-token")
    SECRETS.each do |secret|
      refute_includes out, secret, "stdout carried a secret"
      refute_includes err, secret, "stderr carried a secret"
      refute_includes argv, secret, "a secret rode a child's argv"
    end
  end

  def log(name)
    path = File.join(@dir, "#{name}.log")
    File.exist?(path) ? File.read(path) : ""
  end

  def run_script(*args, env: {})
    base = {
      "HEROKU_STUDIO_ADMIN_API_KEY" => ADMIN_KEY,
      "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => OP_TOKEN,
      "ROTATE_HEROKU_CI_KEY_API_BASE" => "http://127.0.0.1:#{@server.addr[1]}",
      "ROTATE_HEROKU_CI_KEY_OP_BIN" => File.join(@dir, "op"),
      "ROTATE_HEROKU_CI_KEY_GH_BIN" => File.join(@dir, "gh"),
      "ROTATE_HEROKU_CI_KEY_GH_TOKEN_CMD" => File.join(@dir, "gh-token"),
      "ROTATE_HEROKU_CI_KEY_POLL_SECONDS" => "0"
    }
    # The fakes are plain `ruby` children: strip the suite's Bundler environment so
    # they do not boot the app's bundle (and its warnings) on every call.
    bundler = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH RUBYOPT RUBYLIB].to_h { |k| [k, nil] }
    Open3.capture3(SessionEnv.neutralized(bundler.merge(base).merge(env)), "ruby", SCRIPT, *args)
  end

  # ── the fake Heroku Platform API ─────────────────────────────────────────────
  def serve
    while (client = @server.accept)
      handle(client)
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(client)
    verb, path = client.gets.to_s.split
    headers = {}
    while (line = client.gets) && line.strip != ""
      k, v = line.split(":", 2)
      headers[k.downcase] = v.to_s.strip
    end
    body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
    @requests << [verb, path]
    key = headers["authorization"].to_s.delete_prefix("Bearer ")
    code, json = route(verb, path, key, body)
    payload = JSON.generate(json)
    client.write("HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    client.close
  end

  def route(verb, path, key, body)
    case [verb, path]
    in ["GET", "/account"]
      return [401, { "message" => "Invalid credentials provided." }] if key == OLD_KEY && @revoked.include?(OLD_ID)

      [200, { "email" => "alex@mcritchie.studio" }]
    in ["GET", %r{\A/oauth/authorizations/(.+)\z}]
      [200, { "id" => OLD_ID, "description" => "heroku.studio.applications",
              "scope" => %w[identity read-protected write-protected], "access_token" => { "token" => OLD_KEY } }]
    in ["POST", "/oauth/authorizations"]
      raise "mint without scope" unless JSON.parse(body)["scope"] == %w[identity read-protected write-protected]

      [201, { "id" => NEW_ID, "access_token" => { "token" => NEW_KEY } }]
    in ["DELETE", %r{\A/oauth/authorizations/(.+)\z}]
      @revoked << path.split("/").last
      [200, {}]
    in ["GET", %r{\A/apps/[^/]+/releases\z}]
      [206, [{ "version" => 9, "current" => true, "slug" => { "id" => "slug-1" } }]]
    in ["GET", %r{\A/apps/[^/]+/slugs/slug-1\z}]
      [200, { "commit" => SHA }]
    else
      [404, { "message" => "no route #{verb} #{path}" }]
    end
  end

  # ── fake op, gh and gh-token ─────────────────────────────────────────────────
  def write_fakes
    File.write(File.join(@dir, "item.json"), JSON.generate(
      "title" => "heroku.studio.applications",
      "fields" => [{ "label" => "credential", "value" => OLD_KEY }, { "label" => "authorization-id", "value" => OLD_ID }]
    ))
    script("op", <<~RUBY)
      require "json"
      dir = __dir__
      File.open(File.join(dir, "op.log"), "a") { |f| f.puts ARGV.join(" ") }
      item = File.join(dir, "item.json")
      case ARGV.first(2)
      in ["read", ref]
        field = ref.split("/").last
        puts JSON.parse(File.read(item))["fields"].find { |f| f["label"] == field }["value"]
      in ["item", "get"] then print File.read(item)
      in ["item", "edit"] then File.write(item, $stdin.read)
      end
    RUBY
    script("gh", <<~RUBY)
      require "json"
      require "time"
      dir = __dir__
      File.open(File.join(dir, "gh.log"), "a") { |f| f.puts ARGV.join(" ") }
      runs = File.join(dir, "runs.json")
      File.write(runs, "{}") unless File.exist?(runs)
      state = JSON.parse(File.read(runs))
      case ARGV.first(2)
      in ["api", _] then puts JSON.generate("name" => "HEROKU_API_KEY", "updated_at" => Time.now.utc.iso8601)
      in ["secret", "set"] then File.open(File.join(dir, "secret-stdin.log"), "a") { |f| f.puts $stdin.read }
      in ["run", "list"]
        wf = ARGV[ARGV.index("--workflow") + 1]
        puts JSON.generate(state.fetch(wf, []))
      in ["workflow", "run"]
        wf = ARGV[2]
        id = state.values.flatten.map { |r| r["databaseId"] }.max.to_i + 1
        (state[wf] ||= []) << { "databaseId" => id, "status" => "completed", "event" => "workflow_dispatch" }
        File.write(runs, JSON.generate(state))
      in ["run", "view"] then puts JSON.generate("status" => "completed", "conclusion" => "success")
      end
    RUBY
    script("gh-token", <<~RUBY)
      File.open(File.join(__dir__, "gh-token.log"), "a") { |f| f.puts "GH_APP_ITEM=\#{ENV['GH_APP_ITEM']} \#{ARGV.join(' ')}" }
      puts "#{GH_TOKEN}"
    RUBY
  end

  def script(name, body)
    path = File.join(@dir, name)
    File.write(path, "#!/usr/bin/env ruby\n#{body}")
    FileUtils.chmod(0o755, path)
  end
end
