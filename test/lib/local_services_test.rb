# frozen_string_literal: true

# [unit] bin/lib/local_services.rb and bin/ecosystem-build's checklist: the
# always-on service registry, install-if-missing, the Claude Code allow-rule
# merge, and the operator's closing checklist. Every command is a recording
# stub and every path is a throwaway directory: nothing here touches a real
# launchctl, claude or ~/.claude/settings.json.
#   ruby -Itest test/lib/local_services_test.rb
require "minitest/autorun"
require "json"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/local_services"

class LocalServicesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin/ecosystem-build")

  Status = Struct.new(:ok) do
    def success? = ok
  end

  def setup
    @dir = Dir.mktmpdir("local-services")
    @calls = []
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(@dir)

  # ------------------------------------------------------------ registry ----

  def test_the_real_registry_lists_the_dispatcher_first
    services = LocalServices::Registry.load
    first = services.first

    assert_equal "agent-dispatcher", first.name
    assert_equal "bin/dispatcher install", first.install
    assert_equal "bin/dispatcher status", first.status
    assert_equal "claude.ai", first.claude_auth
    assert_includes first.commands, "launchctl"
    assert File.exist?(File.join(ROOT, first.sop)), "the SOP the registry names must exist: #{first.sop}"
  end

  def test_every_registered_sop_and_command_exists
    LocalServices::Registry.load.each do |s|
      assert File.exist?(File.join(ROOT, s.sop)), "#{s.name}: #{s.sop} is missing"
      [ s.install, s.status ].each do |line|
        exe = Shellwords.split(line).first
        assert File.executable?(File.join(ROOT, exe)), "#{s.name}: #{exe} is not an executable in the repo"
      end
    end
  end

  def test_a_registry_entry_missing_its_status_is_refused
    error = assert_raises(LocalServices::Error) { load_yaml(<<~YAML) }
      services:
        - name: x
          sop: docs/x.md
          install: bin/x install
    YAML
    assert_match(/`status` is missing/, error.message)
  end

  def test_unknown_prerequisites_and_duplicate_names_are_refused
    assert_raises(LocalServices::Error) { load_yaml(entry("x", requires: "{ wifi: true }")) }
    error = assert_raises(LocalServices::Error) { load_yaml("#{entry('x')}#{entry('x').sub("services:\n", '')}") }
    assert_match(/duplicate service name/, error.message)
  end

  def test_a_registry_without_a_services_list_is_refused
    assert_raises(LocalServices::Error) { load_yaml("other: []\n") }
  end

  def test_prerequisites_parse
    service = load_yaml(entry("x", requires: "{ claude_auth: claude.ai, commands: [launchctl, claude] }")).first

    assert_equal "claude.ai", service.claude_auth
    assert_equal %w[launchctl claude], service.commands
  end

  # ------------------------------------------- install if missing, idempotent ----

  def test_a_stopped_service_is_installed_then_checked
    running = false
    runner = fake_runner(status: -> { running }, install: -> { running = true })
    items = restorer(runner).run

    assert_equal [ %w[claude auth status], %w[bin/dispatcher status], %w[bin/dispatcher install], %w[bin/dispatcher status] ],
                 @calls.map(&:first)
    assert(@calls.drop(1).all? { |_, dir| dir == "/hub" }, "service commands run from the hub's checkout")
    assert_empty items
    assert_includes @out.string, "installed and running"
  end

  def test_re_running_with_the_service_up_installs_nothing
    running = false
    runner = fake_runner(status: -> { running }, install: -> { running = true })
    restorer(runner).run
    @calls.clear
    restorer(runner).run

    assert_equal [ %w[claude auth status], %w[bin/dispatcher status] ], @calls.map(&:first),
                 "a running service is left alone: no install, so no restart"
  end

  def test_an_install_that_does_not_start_the_service_warns_and_owes_a_step
    items = restorer(fake_runner(status: -> { false }, install: -> {})).run

    assert_equal 1, items.size
    assert_equal LocalServices::Checklist::RANKS[:service], items.first.rank
    assert_match(/agent-dispatcher/, items.first.text)
    assert_match(%r{steffon/sops/agent-dispatcher\.md}, items.first.text)
    assert_includes @out.string, "did not start"
  end

  def test_a_raising_command_is_a_warning_not_a_crash
    runner = lambda do |argv, dir|
      @calls << [ argv, dir ]
      next [ signed_in_json, Status.new(true) ] if argv.first == "claude"

      raise Errno::ENOENT, argv.first
    end
    items = restorer(runner).run

    assert_equal 1, items.size, "the service is owed, the run carries on"
  end

  def test_signed_out_claude_skips_the_service_and_owes_the_sign_in
    runner = fake_runner(status: -> { false }, install: -> { flunk "must not install" }, claude: '{"loggedIn": false}')
    items = restorer(runner).run

    assert_equal [ %w[claude auth status] ], @calls.map(&:first), "a service whose prerequisite fails is not touched"
    login = items.find { |i| i.rank == LocalServices::Checklist::RANKS[:claude_login] }
    refute_nil login
    assert_includes login.command, "claude auth login"
    assert_includes login.command, LocalServices::RERUN
  end

  def test_an_api_key_sign_in_is_not_claude_ai
    items = restorer(fake_runner(status: -> { false }, install: -> { flunk "must not install" },
                                 claude: '{"loggedIn": true, "authMethod": "api_key"}')).run

    assert(items.any? { |i| i.command.include?("claude auth login") })
    assert_includes @out.string, "authMethod: api_key"
  end

  def test_no_claude_owes_the_install_and_the_sign_in_and_runs_nothing
    which = ->(cmd) { cmd != "claude" }
    items = restorer(fake_runner(status: -> { false }, install: -> { flunk "must not install" }), which: which).run

    assert_empty @calls
    assert_equal [ LocalServices::Checklist::RANKS[:claude_install], LocalServices::Checklist::RANKS[:claude_login] ],
                 items.map(&:rank)
  end

  def test_a_missing_launchctl_is_named
    which = ->(cmd) { cmd != "launchctl" }
    items = restorer(fake_runner(status: -> { false }, install: -> { flunk "must not install" }), which: which).run

    assert(items.any? { |i| i.text.include?("launchctl") })
  end

  def test_claude_auth_method_reads_only_the_json_it_trusts
    assert_equal "claude.ai", AgentMailbox::ClaudeAuth.auth_method(signed_in_json)
    assert_nil AgentMailbox::ClaudeAuth.auth_method('{"loggedIn": false, "authMethod": "claude.ai"}')
    assert_nil AgentMailbox::ClaudeAuth.auth_method("Not logged in · Please run /login")
    assert_nil AgentMailbox::ClaudeAuth.auth_method("")
    assert_nil AgentMailbox::ClaudeAuth.auth_method("[1, 2]")
  end

  # ------------------------------------------------------- allow-rule merge ----

  def test_rules_render_the_hub_path
    rules = LocalServices::AllowRules.rules(hub: "/Users/someone/code/mcritchie-studio")

    assert_includes rules, "Bash(bin/dispatcher install)"
    assert_includes rules, "Bash(/Users/someone/code/mcritchie-studio/bin/dispatcher status)"
    refute(rules.any? { |r| r.include?("{{") }, "every placeholder is filled")
    assert_equal 6, rules.size
  end

  def test_merge_into_a_missing_file_creates_valid_json
    path = File.join(@dir, ".claude/settings.json")
    state, added = LocalServices::AllowRules.merge!(path, %w[A B])

    assert_equal :added, state
    assert_equal %w[A B], added
    assert_equal({ "permissions" => { "allow" => %w[A B] } }, JSON.parse(File.read(path)))
  end

  def test_merge_keeps_every_other_key_and_rule_and_adds_no_duplicates
    path = settings(
      "model" => "opus", "hooks" => { "SessionStart" => [ { "hooks" => [ { "type" => "command", "command" => "x" } ] } ] },
      "permissions" => { "allow" => [ "Bash(ls)", "B" ], "deny" => [ "Bash(rm -rf /)" ], "defaultMode" => "default" },
      "statusLine" => { "type" => "command", "command" => "s" }
    )
    before = JSON.parse(File.read(path))
    state, added = LocalServices::AllowRules.merge!(path, %w[A B C A])
    after = JSON.parse(File.read(path))

    assert_equal :added, state
    assert_equal %w[A C], added
    assert_equal [ "Bash(ls)", "B", "A", "C" ], after["permissions"]["allow"], "existing rules first, in their order"
    assert_equal before.except("permissions"), after.except("permissions")
    assert_equal before["permissions"].except("allow"), after["permissions"].except("allow")
  end

  def test_a_second_merge_writes_nothing
    path = settings("permissions" => { "allow" => [] })
    LocalServices::AllowRules.merge!(path, %w[A])
    mtime = File.mtime(path)
    bytes = File.read(path)
    sleep 0.01

    assert_equal [ :current, [] ], LocalServices::AllowRules.merge!(path, %w[A])
    assert_equal bytes, File.read(path)
    assert_equal mtime, File.mtime(path)
  end

  def test_merge_keeps_the_file_mode_and_leaves_no_temp_file
    path = settings({})
    File.chmod(0o640, path)
    LocalServices::AllowRules.merge!(path, %w[A])

    assert_equal 0o640, File.stat(path).mode & 0o777
    assert_equal [ "settings.json" ], Dir.children(File.dirname(path))
  end

  def test_a_symlinked_settings_file_is_written_through
    real = settings({ "model" => "x" })
    link = File.join(@dir, "link.json")
    File.symlink(real, link)
    LocalServices::AllowRules.merge!(link, %w[A])

    assert File.symlink?(link), "the link survives"
    assert_equal %w[A], JSON.parse(File.read(real))["permissions"]["allow"]
  end

  def test_invalid_json_and_wrong_shapes_are_refused_untouched
    {
      "{ not json" => /not valid JSON/,
      "[1]" => /not a JSON object/,
      '{"permissions": []}' => /permissions is not an object/,
      '{"permissions": {"allow": "Bash(ls)"}}' => /allow is not a list/
    }.each do |content, why|
      path = File.join(@dir, "s.json")
      File.write(path, content)
      state, reason = LocalServices::AllowRules.merge!(path, %w[A])

      assert_equal :refused, state, content
      assert_match why, reason
      assert_equal content, File.read(path), "a refused file is left exactly as it was"
    end
  end

  # ------------------------------------------------------- checklist render ----

  def test_the_script_ranks_match_the_ruby_ranks
    src = File.read(SCRIPT)
    script_ranks = src.scan(/^RANK_([A-Z_]+)=(\d+)$/).to_h { |k, v| [ k.downcase.to_sym, Integer(v) ] }

    refute_empty script_ranks
    script_ranks.each do |name, rank|
      assert_equal LocalServices::Checklist::RANKS.fetch(name), rank, "RANK_#{name.upcase} drifted from RANKS"
    end
  end

  def test_the_checklist_is_numbered_in_rank_order_and_deduplicated
    out = render_with([
      [ 70, "Chrome", "bin/chrome-profiles apply" ],
      [ 20, "Token", "bin/setup-1pass-token" ],
      [ 40, "Sign in", "claude auth login" ],
      [ 20, "Token", "bin/setup-1pass-token" ],
      [ 40, "Second at forty", "" ]
    ])
    lines = out.lines.map(&:rstrip).reject(&:empty?)

    assert_equal "═══ What only you can do ═══", lines.first
    assert_equal [ "  1. Token", "       bin/setup-1pass-token", "  2. Sign in", "       claude auth login",
                   "  3. Second at forty", "  4. Chrome", "       bin/chrome-profiles apply" ], lines.drop(1)
  end

  def test_an_empty_checklist_says_nothing_is_owed
    assert_match(/Nothing\. Every service is running/, render_with([]))
  end

  def test_ruby_items_render_through_the_same_file
    item = LocalServices::Item.new(rank: 40, text: "has\ta tab", command: "claude auth login")
    line = LocalServices::Checklist.line(item)

    assert_equal "40\thas a tab\tclaude auth login", line
  end

  def test_checklist_add_flattens_tabs_and_newlines
    out = bash(<<~SH)
      source "#{SCRIPT}"
      checklist_add 5 "two"$'\\t'"words" "line"$'\\n'"break"
      render_checklist
    SH
    assert_includes out, "1. two words"
    assert_includes out, "line break"
  end

  private

  def load_yaml(text)
    path = File.join(@dir, "services.yml")
    File.write(path, text)
    LocalServices::Registry.load(path)
  end

  def entry(name, requires: "{}")
    "services:\n  - name: #{name}\n    sop: docs/x.md\n    install: bin/x install\n    status: bin/x status\n" \
      "    requires: #{requires}\n"
  end

  def signed_in_json = '{"loggedIn": true, "authMethod": "claude.ai", "email": "someone@example.com"}'

  def fake_runner(status:, install:, claude: signed_in_json)
    lambda do |argv, dir|
      @calls << [ argv, dir ]
      case argv
      when %w[claude auth status] then [ claude, Status.new(true) ]
      when %w[bin/dispatcher status] then [ "", Status.new(status.call) ]
      when %w[bin/dispatcher install] then install.call
                                           [ "installed", Status.new(true) ]
      else flunk "unexpected command #{argv.inspect}"
      end
    end
  end

  def restorer(runner, which: ->(_) { true })
    LocalServices::Restorer.new(services: LocalServices::Registry.load.first(1), hub: "/hub", runner: runner,
                                which: which, out: @out)
  end

  def settings(data)
    path = File.join(@dir, ".claude/settings.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data))
    path
  end

  def render_with(rows)
    file = File.join(@dir, "checklist.tsv")
    File.write(file, rows.map { |r| r.join("\t") }.join("\n").then { |s| s.empty? ? s : "#{s}\n" })
    bash(%(source "#{SCRIPT}"; CHECKLIST_FILE="#{file}"; render_checklist))
  end

  # The script's own functions, sourced (it runs nothing when sourced) with no
  # TTY, so no colour codes.
  def bash(code)
    out, status = Open3.capture2e({ "HOME" => @dir, "PROJECTS_DIR" => File.join(@dir, "projects") }, "bash", "-c", code)
    assert status.success?, out
    out
  end
end
