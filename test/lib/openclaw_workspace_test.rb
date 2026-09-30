# frozen_string_literal: true

# [unit] bin/openclaw-workspace and lib/openclaw_workspace.rb: a fleet soul's
# docs become an OpenClaw workspace (SOUL.md, AGENTS.md, IDENTITY.md) under
# OpenClaw's injection caps, links flattened, the agent's memory untouched.
#
#   ruby -Itest test/lib/openclaw_workspace_test.rb

require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../../lib/openclaw_workspace"

class OpenclawWorkspaceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DOCS = File.join(ROOT, "docs/agents/agents")

  def test_tyrion_builds_from_his_manifest_under_the_caps
    files = OpenclawWorkspace.new("tyrion", docs_root: DOCS).files
    assert_equal %w[SOUL.md AGENTS.md IDENTITY.md], files.keys
    assert_includes files["SOUL.md"], "# Tyrion — Soul"
    assert_includes files["SOUL.md"], "# Tyrion — Voice at the Table"
    assert_includes files["AGENTS.md"], "# Tyrion — On Discord"
    assert_includes files["AGENTS.md"], "The Lannister Debt"
    assert_includes files["IDENTITY.md"], "**Name:** Tyrion"
    files.each_value { |text| assert_operator text.length, :<=, OpenclawWorkspace::FILE_CAP }
    assert_operator files.values.sum(&:length), :<=, OpenclawWorkspace::TOTAL_CAP
  end

  def test_tyrion_gets_no_operator_doc_and_no_secret
    files = OpenclawWorkspace.new("tyrion", docs_root: DOCS).files
    all = files.values.join
    refute_includes all, "# Tyrion — Runtime", "runtime.md is the operators' design, not his"
    refute_match(%r{op://|sk-ant-|cyb_[A-Za-z0-9]{10}}, all)
  end

  def test_links_between_repo_docs_are_flattened_and_web_links_kept
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "sam"))
      File.write(File.join(root, "sam/soul.md"), "See [the role](role.md#x) and [the site](https://example.com).")
      File.write(File.join(root, "sam/role.md"), "Role.")
      files = OpenclawWorkspace.new("sam", docs_root: root).files
      assert_includes files["SOUL.md"], "See the role and [the site](https://example.com)."
      assert_equal "Role.\n", files["AGENTS.md"], "no manifest: AGENTS.md is role.md"
      assert_includes files["IDENTITY.md"], "# Sam"
    end
  end

  def test_every_fleet_soul_fits_the_defaults
    Dir.children(DOCS).select { |soul| File.file?(File.join(DOCS, soul, "soul.md")) && File.file?(File.join(DOCS, soul, "role.md")) }.each do |soul|
      OpenclawWorkspace.new(soul, docs_root: DOCS).files
    end
  end

  def test_over_the_cap_or_missing_doc_refuses
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "big"))
      File.write(File.join(root, "big/soul.md"), "x" * 20_001)
      File.write(File.join(root, "big/role.md"), "r")
      error = assert_raises(OpenclawWorkspace::Error) { OpenclawWorkspace.new("big", docs_root: root).files }
      assert_match(/at most 20000/, error.message)

      File.write(File.join(root, "big/soul.md"), "s")
      File.write(File.join(root, "big/openclaw.yml"), "SOUL.md: [missing.md]\n")
      error = assert_raises(OpenclawWorkspace::Error) { OpenclawWorkspace.new("big", docs_root: root).files }
      assert_match(/missing\.md/, error.message)
    end
    assert_raises(OpenclawWorkspace::Error) { OpenclawWorkspace.new("../etc", docs_root: DOCS) }
    assert_raises(OpenclawWorkspace::Error) { OpenclawWorkspace.new("nobody", docs_root: DOCS) }
  end

  def test_the_command_writes_three_files_and_leaves_memory_alone
    Dir.mktmpdir do |out|
      File.write(File.join(out, "MEMORY.md"), "what he learned")
      stdout, status = Open3.capture2e(File.join(ROOT, "bin/openclaw-workspace"), "tyrion", out)
      assert status.success?, stdout
      assert_equal %w[AGENTS.md IDENTITY.md MEMORY.md SOUL.md], Dir.children(out).sort
      assert_equal "what he learned", File.read(File.join(out, "MEMORY.md"))
    end
  end

  def test_help_writes_nothing_and_a_stray_argument_refuses
    Dir.mktmpdir do |out|
      stdout, status = Open3.capture2e(File.join(ROOT, "bin/openclaw-workspace"), "tyrion", out, "--help")
      assert status.success?
      assert_match(/Usage/, stdout)
      _out, status = Open3.capture2e(File.join(ROOT, "bin/openclaw-workspace"), "tyrion", out, "extra")
      refute status.success?
      assert_empty Dir.children(out)
    end
  end
end
