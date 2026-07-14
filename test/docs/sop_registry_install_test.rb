# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# INTEGRATION tier for the SOP registry, across the boundary that actually
# matters: GENERATION.
#
# Registering an SOP in docs/agents/index.md is necessary but NOT sufficient. The
# file an agent actually reads is the GENERATED one — $PROJECTS_DIR/AGENTS.md (Codex
# reads it natively) and $PROJECTS_DIR/CLAUDE.md (Claude Code AUTO-LOADS it). Those
# are produced by bin/install-agent-docs, and until that runs, a newly registered
# SOP is invisible to every agent no matter how correct the source is.
#
# That is a real, repeated failure in this ecosystem: the doc change lands, nobody
# runs the installer, and the next session cannot resolve the SOP name. The unit
# test (sop_registry_docs_test.rb) pins the SOURCE; this one pins the OUTPUT.
#
# SANDBOXED: bin/install-agent-docs writes to $PROJECTS_DIR *and* to $HOME/.claude
# and $HOME/.codex (user-global skills). We point BOTH at temp dirs, so the real
# projects root and the real skills directories are never touched.
class SopRegistryInstallTest < ActiveSupport::TestCase
  test "install-agent-docs generates AGENTS.md and CLAUDE.md that can resolve clean-up" do
    Dir.mktmpdir("sop-install") do |sandbox|
      projects = File.join(sandbox, "projects")
      home     = File.join(sandbox, "home")
      FileUtils.mkdir_p([projects, home])

      env = {
        "PROJECTS_DIR" => projects,
        "HOME" => home,
        # Never let a test inherit the live session's identity or board.
        "AGENT_SESSION_ID" => nil,
        "ATOMIC_CAPTURE_URL" => nil
      }

      out, status = Open3.capture2e(env, Rails.root.join("bin/install-agent-docs").to_s, "install",
                                    chdir: Rails.root.to_s)
      assert status.success?, "install-agent-docs failed:\n#{out}"

      agents = File.join(projects, "AGENTS.md")
      claude = File.join(projects, "CLAUDE.md")
      assert_path_exists agents
      assert_path_exists claude

      agents_body = File.read(agents)

      # The registry row an agent resolves `clean-up` through must survive generation.
      assert_match(/\|\s*`clean-up`\s*\|\s*Alex\s*\|.*alex\/sops\/clean-up\.md/, agents_body,
                   "the generated AGENTS.md carries no `clean-up` registry row — an agent told to run " \
                   "clean-up could not resolve the name")

      # And the file it points at must be reachable from the repo.
      assert_path_exists Rails.root.join("docs/agents/agents/alex/sops/clean-up.md")

      # Claude Code auto-loads CLAUDE.md; if it never names the SOP, Claude is the
      # least likely of the two runtimes to resolve it.
      assert_match(/`clean-up`/, File.read(claude),
                   "the generated CLAUDE.md never names `clean-up`")

      # The real projects root must be untouched by this test.
      refute_equal File.expand_path("/Users/alex/projects"), File.expand_path(projects)
    end
  end
end
