# frozen_string_literal: true

# `bin/release status` lists each registered gem's BURNED versions: finals a prepare
# published that no release shipped, `burned-v<x.y.z>` tags (record_burned_finals!).
# Read-only: origin by `git ls-remote`, else the clone's tags. Shared harness:
# test/lib/release_cli_harness.rb. Only git reads are stubbed (ladder as in
# release_cli_status_test.rb), so the REAL burned_gems_report, burned_gem_read and status
# run.
# History: task release-docs-second-pass.

require_relative "release_cli_harness"

class ReleaseCliBurnedStatusTest < ReleaseCliHarness
  LADDER = { pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }] }.freeze

  # `origin` answers the ls-remote (or fails), `local` answers `tag --list`.
  def git_stub(origin:, local: "")
    <<~RUBY
      def repo_path(_repo) = #{self.class.stub_repo.inspect}
      alias __real_git_capture git_capture
      def git_capture(*a)
        joined = a.join(" ")
        if joined.include?("ls-remote --tags origin refs/tags/burned-v*")
          $stdout.puts("LS-REMOTE")
          return #{origin.inspect}.nil? ? ["fatal: could not read from remote", false] : [#{origin.inspect}, true]
        end
        return [#{local.inspect}, true] if joined.include?("tag --list burned-v*")
        raise "status must not fetch: \#{joined}" if joined.include?("fetch")

        __real_git_capture(*a)
      end
    RUBY
  end

  def status_with(stub)
    run_cli(["status"], setup: status_stub(**LADDER) + stub, call: "status; puts('DONE-NO-ABORT')")
  end

  def test_status_lists_burned_versions_read_from_origin
    origin = "aaa\trefs/tags/burned-v1.0.0\nbbb\trefs/tags/burned-v1.0.0^{}\nccc\trefs/tags/burned-v0.9.1\n"
    out = status_with(git_stub(origin: origin))

    assert_includes out, "Burned gem versions (published at a prepare, never shipped):"
    assert_includes out, "BURNED studio-engine 0.9.1, 1.0.0 — published, never shipped: no consumer may lock them"
    assert_includes out, "LS-REMOTE", "origin is the record, so status asks it"
    refute_includes out, "local tags", "an origin read is not labelled as a local one"
    assert_includes out, "DONE-NO-ABORT", "a burned version is reported, never a reason for status to abort"
  end

  def test_status_falls_back_to_local_tags_and_says_so_when_origin_is_unreadable
    out = status_with(git_stub(origin: nil, local: "burned-v1.0.0\n"))

    assert_match(/BURNED studio-engine 1\.0\.0 \(local tags; origin unreadable, may miss a newer burn\)/, out)
  end

  def test_status_says_none_only_for_a_gem_it_read
    out = status_with(git_stub(origin: ""))

    assert_includes out, "studio-engine: no burned versions"
    refute_includes out, "BURNED studio-engine"
  end

  def test_a_failing_burned_read_never_breaks_status
    stub = %(def burned_gem_read(_gem) = raise("kaboom")\n)
    out = status_with(stub)

    assert_includes out, "BURNED GEM VERSIONS: cannot confirm — the check failed"
    assert_includes out, "DONE-NO-ABORT"
  end
end
