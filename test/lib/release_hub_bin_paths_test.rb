# frozen_string_literal: true

# [unit] bin/release spawns its hub tools from the hub root, never from the caller's cwd.
#
# rel-20261110-208612: `bin/release prepare` run with cwd /Users/alex/projects failed all
# three QA deploys with ENOENT ("could not run bin/qa-server: No such file or directory").
# qa_deploy_app! spawned a bare "bin/qa-server", which the OS resolves against the cwd.
# The class was wider than that one line: the archive pruners, the worktree reclaim, the
# primary restore and the --local conductor did the same. HUB_ROOT / hub_bin now name each.
# History: task release-prepare-night-lessons.
require "tmpdir"
require_relative "release_cli_harness"
require_relative "../../app/models/release/qa_deploy_command"

class ReleaseHubBinPathsTest < ReleaseCliHarness
  HUB = File.expand_path("../..", __dir__)

  def test_qa_deploy_argv_names_the_script_under_the_hub_root
    argv = Release::QaDeployCommand.argv(qa_app: "voicebox", branch: "release", hub_root: HUB)

    assert_equal [File.join(HUB, "bin", "qa-server"), "deploy", "voicebox", "origin/release", "--yes"], argv
    Dir.chdir(Dir.tmpdir) do
      assert File.executable?(argv.first), "the script resolves from a cwd outside the hub: #{argv.first}"
    end
  end

  def test_the_printed_remedy_is_the_same_command_as_the_spawn
    argv = Release::QaDeployCommand.argv(qa_app: "voicebox", branch: "release", hub_root: HUB)

    assert_equal argv.join(" "), Release::QaDeployCommand.for(qa_app: "voicebox", branch: "release", hub_root: HUB)
  end

  # The control: without a hub root the script path is the relative one the night's
  # prepare spawned, and from a cwd outside the hub it does not exist.
  def test_control_the_relative_script_does_not_resolve_outside_the_hub
    argv = Release::QaDeployCommand.argv(qa_app: "voicebox", branch: "release")

    assert_equal "bin/qa-server", argv.first
    Dir.chdir(Dir.tmpdir) { refute File.exist?(argv.first), "the relative path must miss from a foreign cwd" }
  end

  # The real qa_deploy_app! from a cwd outside the hub: the spawn it hands sh is an
  # absolute path that exists. Reverting the call site to sh("bin/qa-server", …) reds this.
  def test_qa_deploy_app_spawns_qa_server_by_absolute_path_from_any_cwd
    setup = <<~'RUBY'
      def sh(*a, **k)
        if a[0].to_s.end_with?("qa-server")
          puts("QA-ARGV0=" + a[0].to_s + " EXISTS=" + File.exist?(a[0].to_s).to_s)
          return ["", false]
        end
        ["", true]
      end
      def say_event(text) = puts(text)
      def repo_path(_repo) = Dir.tmpdir
    RUBY
    group = { "repo" => "voicebox", "kind" => "app", "qa_app" => "voicebox", "members" => [{ "slug" => "t-v" }] }
    call = "Dir.chdir(#{Dir.tmpdir.inspect}) { begin; qa_deploy_app!(#{group.inspect}, smoke_started: -> {}); " \
           "rescue SystemExit, NoMethodError, ArgumentError => e; puts('STOPPED ' + e.class.to_s); end }"
    out = run_cli(["--yes"], setup: setup, call: call)

    argv0 = out[/QA-ARGV0=(\S+)/, 1]
    refute_nil argv0, out
    assert argv0.start_with?("/"), "qa-server is spawned by an absolute path: #{argv0}"
    assert_includes out, "EXISTS=true", out
  end

  # The class, held at the source. A hub tool named as a bare "bin/<tool>" in a spawn
  # resolves against the cwd. Only a repo's OWN binstub run with chdir: into that repo
  # (bin/rails, bin/bundle) may stay relative.
  def test_bin_release_spawns_no_hub_tool_by_a_cwd_relative_path
    allowed = %w[bin/rails bin/bundle]
    offenders = File.readlines(BIN).each_with_index.flat_map do |line, i|
      next [] if line.strip.start_with?("#")

      line.scan(/(?:sh|capture2e|capture3|run_pruner|BoundedCommand\.\w+)\(\s*\[?"(bin\/[\w-]+)"|=\s*\["(bin\/[\w-]+)"|:\s*\["(bin\/[\w-]+)"/)
          .flatten.compact.reject { |tool| allowed.include?(tool) && line.include?("chdir:") }
          .reject { |tool| tool == "bin/bundle" && line.include?("File.exist?(File.join(path") }
          .map { |tool| "bin/release.rb:#{i + 1}: #{tool}" }
    end

    assert_empty offenders, "spawn hub tools through hub_bin(name), not a cwd-relative path"
  end

  def test_hub_bin_resolves_under_the_script_checkout
    assert_equal File.join(HUB, "bin", "agent-worktree"), eval_helper(%(hub_bin("agent-worktree")))
  end
end
