# frozen_string_literal: true

# [unit] Every bin script resolves its siblings independent of the caller's cwd.
#
# A spawn of a bare "bin/<tool>" resolves against the cwd, so the fixed-path tooling
# (<projects>/.agents/bin) run from anywhere but the hub root fails with ENOENT, or
# runs ANOTHER checkout's tool. bin/release did it with bin/qa-server (fixed in
# release-prepare-night-lessons, held by release_hub_bin_paths_test.rb); bin/devops-reconcile
# did it with bin/task. This guard holds the class over every Ruby script in bin/ and
# bin/lib. A spawn may stay relative only when it runs with `chdir:` (a repo's own
# binstub, run inside that repo) or in a script that pins its cwd with Dir.chdir first.
# History: task release-preflight-hardening.
require "minitest/autorun"

class BinCwdIndependenceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SPAWN = /\b(?:sh|system|capture2e|capture2|capture3|popen|spawn|exec)\s*\(\s*(?:[a-z_]*env[a-z_]*\s*,\s*|\{[^}]*\}\s*,\s*)?\[?\s*"(bin\/[\w.-]+)"|=\s*`(bin\/[\w.-]+)/

  def ruby_scripts
    bins = Dir[File.join(ROOT, "bin", "*")].select do |path|
      File.file?(path) && (path.end_with?(".rb") || File.open(path, &:gets).to_s.include?("ruby"))
    end
    bins + Dir[File.join(ROOT, "bin", "lib", "**", "*.rb")]
  end

  def offenders_in(path, text)
    return [] if text.match?(/^\s*Dir\.chdir\((?:ROOT|APP_ROOT|File\.expand_path\("\.\.", __dir__\))\)\s*$/)

    text.lines.each_with_index.flat_map do |line, i|
      next [] if line.strip.start_with?("#") || line.include?("chdir:")

      line.scan(SPAWN).flatten.compact.map { |tool| "#{path.delete_prefix("#{ROOT}/")}:#{i + 1}: #{tool}" }
    end
  end

  def test_the_scan_reads_the_scripts
    assert_operator ruby_scripts.size, :>, 50
  end

  # The control: the pattern catches the shape bin/devops-reconcile shipped with.
  def test_control_the_pattern_catches_a_bare_sibling_spawn
    found = offenders_in("x", %(ok = sh("bin/task", "merged", slug, "accepted")\n))
    assert_equal ["x:1: bin/task"], found
    assert_empty offenders_in("x", %(sh("bin/rails", "test", chdir: dir)\n))
  end

  def test_no_bin_script_spawns_a_sibling_by_a_cwd_relative_path
    offenders = ruby_scripts.flat_map { |path| offenders_in(path, File.read(path)) }

    assert_empty offenders, "spawn a sibling by File.join(__dir__, name) (or hub_bin), or pass chdir:"
  end

  # The fix, end to end: bin/devops-reconcile names bin/task by its own directory.
  def test_devops_reconcile_names_bin_task_by_its_own_directory
    source = File.read(File.join(ROOT, "bin", "devops-reconcile"))
    assert_includes source, %(File.join(__dir__, "task"))
  end
end
