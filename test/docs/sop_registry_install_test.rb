# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "digest"

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
    real_root_digest = digest_of(REAL_ROOT_DOCS)

    Dir.mktmpdir("sop-install") do |sandbox|
      projects = File.join(sandbox, "projects")
      home     = File.join(sandbox, "home")
      FileUtils.mkdir_p([projects, home])

      # EVERY destination the installer can write to must land inside the sandbox.
      #
      # The first cut pinned HOME and PROJECTS_DIR and stopped there — which left
      # CODEX_REQUIREMENTS_PATH defaulting to **/etc/codex/requirements.toml**, wholly
      # outside the sandbox, and the runtime root unpinned. It guarded the escape
      # hatches I happened to remember. That is precisely the failure this test exists
      # to catch, committed by the test itself.
      #
      # So the rule is inverted: enumerate the installer's write destinations from the
      # SCRIPT (grep its `*_PATH` / `*_ROOT` / `*_DIR` defaults), pin every one, and
      # then ASSERT below that nothing outside the sandbox changed — so the next
      # destination somebody adds is caught by a red test, not by a reviewer.
      env = {
        "PROJECTS_DIR" => projects,
        "HOME" => home,
        "CODEX_REQUIREMENTS_PATH" => File.join(sandbox, "etc-codex", "requirements.toml"),
        "AGENT_DOCS_RUNTIME_ROOT" => File.join(sandbox, "runtime"),
        "AGENT_RUNTIME_ZPROFILE" => File.join(home, ".zprofile"),
        # Never let a test inherit the live session's identity or board.
        "AGENT_SESSION_ID" => nil,
        "ATOMIC_CAPTURE_URL" => nil,
        "AGENT_ACTIVITY_BOARD_URL" => "http://localhost:0",
        "AGENT_INSIGHTS_BOARD_URL" => "http://localhost:0"
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
      #
      # The obvious spelling — `refute_equal "/Users/alex/projects", projects` — is
      # TAUTOLOGICAL: `projects` is an mktmpdir path, so it can never equal the real
      # root, and the assertion passes even if the installer wrote to the real root
      # anyway. A guard that cannot fail is not a guard. Compare the real files'
      # CONTENT across the run instead: that is the property we actually want.
      assert_equal real_root_digest, digest_of(REAL_ROOT_DOCS),
                   "install-agent-docs MODIFIED the real projects root while sandboxed to a tmpdir — " \
                   "HOME/PROJECTS_DIR did not contain it"
    end
  end

  # Every path OUTSIDE the sandbox that bin/install-agent-docs can write to. Keep this
  # list honest: it is the blast radius of a mis-sandboxed run of this very test.
  REAL_ROOT_DOCS = [
    File.expand_path("~/projects/AGENTS.md"),
    File.expand_path("~/projects/CLAUDE.md"),
    File.expand_path("~/.claude/skills"),
    File.expand_path("~/.codex/skills"),
    File.expand_path("~/.zprofile"),
    "/etc/codex/requirements.toml"
  ].freeze

  # THE DURABLE HALF. The list above is a blacklist, and a blacklist always misses one —
  # this test's own first cut missed /etc/codex. So ALSO assert the POSITIVE invariant:
  # every write destination the SCRIPT names must be overridable, and this test must pin
  # every one of them. Add a new `FOO_PATH="${FOO_PATH:-/somewhere/real}"` to the
  # installer without pinning it here and THIS goes red — before it can escape.
  test "every overridable write destination in install-agent-docs is pinned by this test" do
    script = Rails.root.join("bin/install-agent-docs").read

    # `NAME="${NAME:-<default>}"` — the script's own escape-hatch idiom. Absolute
    # defaults are the ones that can escape a sandbox; relative ones resolve under $ROOT.
    escapes = script.scan(/^(\w+)="\$\{\1:-(\/[^}"]+)\}"/).to_h

    pinned = %w[PROJECTS_DIR HOME CODEX_REQUIREMENTS_PATH AGENT_DOCS_RUNTIME_ROOT
                AGENT_RUNTIME_ZPROFILE AGENT_ACTIVITY_BOARD_URL AGENT_INSIGHTS_BOARD_URL]

    unpinned = escapes.keys - pinned

    assert_empty unpinned,
                 "bin/install-agent-docs can write to an ABSOLUTE path via #{unpinned.inspect}, and this " \
                 "test does not pin it — so running the installer under test would escape the sandbox and " \
                 "touch the real machine (defaults: #{escapes.slice(*unpinned).values.inspect}). Pin it in " \
                 "the `env` hash AND add it to REAL_ROOT_DOCS."
  end

  # Content fingerprint of the real installed docs + skills tree. Missing paths hash
  # as "absent" — so a test that CREATES one is caught too, not just one that edits.
  def digest_of(paths)
    paths.map do |path|
      if File.file?(path) then Digest::SHA256.file(path).hexdigest
      elsif File.directory?(path) then Dir.glob("#{path}/**/*").sort.map { |f| "#{f}:#{File.file?(f) ? Digest::SHA256.file(f).hexdigest : "d"}" }.join
      else "absent"
      end
    end
  end
end
