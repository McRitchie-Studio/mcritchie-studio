# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

class CodexUpdateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "codex-update")

  def setup
    @tmp = Dir.mktmpdir("codex-update")
    @home = File.join(@tmp, "home")
    @packages = File.join(@home, ".codex", "packages", "standalone")
    @releases = File.join(@packages, "releases")
    @current = File.join(@packages, "current")
    @config = File.join(@home, ".codex", "config.toml")
    @sentinel = File.join(@home, ".codex", "mcritchie-live-thread-title.enabled")
    FileUtils.mkdir_p(@releases)
    @patched = make_runtime("0.142.3", "patched", support: true)
    @stock = make_runtime("0.142.4", "stock", support: false)
    File.symlink(@patched, @current)
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def default_env
    {
      "BUNDLE_BIN_PATH" => nil,
      "BUNDLE_GEMFILE" => nil,
      "RUBYLIB" => nil,
      "RUBYOPT" => nil,
      "HOME" => @home,
      "CODEX_HOME" => File.join(@home, ".codex"),
      "CODEX_UPDATE_CODEX_BIN" => File.join(@current, "bin", "codex"),
      "CODEX_UPDATE_LATEST_VERSION" => "0.142.4",
      "CODEX_UPDATE_RELEASE_URL" => "https://github.com/openai/codex/releases/tag/v0.142.4",
      "CODEX_UPDATE_RELEASE_BODY" => "Test release notes",
      "CODEX_UPDATE_CONFIG" => @config,
      "CODEX_UPDATE_LIVE_SENTINEL" => @sentinel,
      "CODEX_UPDATE_ARCH_TRIPLE" => "aarch64-apple-darwin"
    }
  end

  def run_cmd(*args, env: {})
    Open3.capture3(default_env.merge(env), RbConfig.ruby, "--disable=gems", SCRIPT, *args)
  end

  def make_runtime(version, name, support:)
    target = File.join(@releases, "#{version}-aarch64-apple-darwin-#{name}")
    bin = File.join(target, "bin", "codex")
    FileUtils.mkdir_p(File.dirname(bin))
    marker = if support
               <<~TEXT
                 # McRitchie session marker:
                 # hookSpecificOutput threadName
                 # struct SessionStartHookSpecificOutputWire with 3 elements
               TEXT
             else
               "# struct SessionStartHookSpecificOutputWire with 2 elements\n"
             end
    File.write(bin, <<~BASH)
      #!/usr/bin/env bash
      if [ "$1" = "--version" ]; then
        printf 'codex-cli #{version}\\n'
        exit 0
      fi
      exit 0
      #{marker}
    BASH
    FileUtils.chmod(0o755, bin)
    target
  end

  def switch_script(target)
    path = File.join(@tmp, "switch-current")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "fileutils"
      FileUtils.rm_f(#{@current.inspect})
      File.symlink(#{target.inspect}, #{@current.inspect})
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  def current_realpath
    File.realpath(@current)
  end

  def test_plan_json_reviews_latest_and_current_hook_support
    out, err, status = run_cmd("plan", "--json")

    assert status.success?, err
    payload = JSON.parse(out)
    assert_equal "0.142.3", payload.fetch("current_version")
    assert_equal "0.142.4", payload.dig("latest", "version")
    assert_equal true, payload.dig("inspection", "thread_name_hook_output")
    assert_match(%r{docs/agents/patches/codex-0\.142\.3}, payload.fetch("patch_path"))
  end

  def test_inspect_fails_closed_for_stock_binary_without_thread_name_hook
    out, err, status = run_cmd("inspect", "--binary", File.join(@stock, "bin", "codex"), "--json")

    assert_empty err
    assert_equal 2, status.exitstatus
    payload = JSON.parse(out)
    assert_equal false, payload.fetch("thread_name_hook_output")
    assert_equal true, payload.fetch("stock_without_thread_name")
  end

  def test_run_rolls_back_when_stock_update_lacks_hook_support
    install = switch_script(@stock)

    _out, err, status = run_cmd("run", "--yes", "--install-command", install)

    assert_equal 2, status.exitstatus
    assert_match(/restored/, err)
    assert_equal File.realpath(@patched), current_realpath
    assert File.file?(@sentinel), "rollback should keep live thread-title repaint enabled"
    assert_match(/^check_for_update_on_startup = false$/, File.read(@config))
  end

  def test_promote_switches_only_a_hook_capable_binary
    built = File.join(@tmp, "built-codex")
    FileUtils.cp(File.join(@patched, "bin", "codex"), built)
    FileUtils.chmod(0o755, built)

    out, err, status = run_cmd("promote", "--binary", built, "--version", "0.200.0", "--yes")

    assert status.success?, err
    assert_match(/Promoted patched Codex 0\.200\.0/, out)
    assert_match(%r{0\.200\.0-aarch64-apple-darwin\z}, current_realpath)
    assert File.file?(@sentinel), "promote should enable live thread-title repaint"
    assert_match(/^check_for_update_on_startup = false$/, File.read(@config))

    last_good = JSON.parse(File.read(File.join(@home, ".codex", "mcritchie-codex-update", "last-good.json")))
    assert_equal File.realpath(@patched), File.realpath(last_good.fetch("target"))
  end
end
