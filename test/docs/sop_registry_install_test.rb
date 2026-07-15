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
        "AGENT_RUNTIME_RUBY_PATH_PREFIX" => File.join(sandbox, "ruby-bin"),
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
  # every ABSOLUTE default the installer can be pointed at must be pinned by this test.
  #
  # ⛔ THE FIRST CUT OF *THIS GUARD* WAS ITSELF INERT, and the way it failed is the whole
  # lesson. It scanned for `NAME="${NAME:-/abs}"` with a BACKREFERENCE — which forces the
  # shell variable's name to EQUAL the env-var's name. That is the installer's MINORITY
  # spelling. Three of its five hatches read `LOCAL="${AGENT_ENV_NAME:-/abs}"`, where the
  # two names DIFFER:
  #
  #     RUNTIME_ROOT="${AGENT_DOCS_RUNTIME_ROOT:-$(runtime_root)}"
  #     RUBY_PATH_PREFIX="${AGENT_RUNTIME_RUBY_PATH_PREFIX:-/opt/homebrew/...}"
  #     ZPROFILE_PATH="${AGENT_RUNTIME_ZPROFILE:-$HOME/.zprofile}"
  #
  # …so the scan saw ONE destination out of five, the `pinned` list carried six names the
  # regex could never emit (an illusion of coverage), and with no non-empty floor the whole
  # assertion could pass while checking NOTHING. Both reviewers defeated it by adding a
  # write path to the operator's real ~/.claude/skills in the script's own house style.
  #
  # The rule this violated is written one file over, in sop_registry_docs_test.rb:
  # "A subset assertion over an EMPTY set passes trivially — the exact way this family of
  # test fails open." Hence: capture BOTH names independently, and assert a floor.
  test "every overridable write destination in install-agent-docs is pinned by this test" do
    script = Rails.root.join("bin/install-agent-docs").read

    # ⛔ DO NOT CLASSIFY THE DEFAULT. That is the trap, and this test fell into it TWICE.
    #
    # Cut 1 keyed on `NAME="${NAME:-…}"` with a BACKREFERENCE — blind to the installer's
    # majority idiom, where the shell variable and the env variable have DIFFERENT names.
    # Cut 2 then filtered to defaults that "look absolute" (`start_with?("/", "$HOME")`).
    # Two reviewers defeated THAT independently, without inventing anything, using two
    # idioms the script ALREADY uses:
    #
    #   COMPUTED   PROJECTS_DIR="${PROJECTS_DIR:-$(default_projects_dir)}"    -> ~/projects
    #              RUNTIME_ROOT="${AGENT_DOCS_RUNTIME_ROOT:-$(runtime_root)}" -> the studio repo
    #   NESTED     ACTIVITY_BOARD_URL="${AGENT_ACTIVITY_BOARD_URL:-${AGENT_INSIGHTS_BOARD_URL:-…}}"
    #
    # Both resolve absolute at RUNTIME. Both were invisible. Each cut replaced one
    # blacklist with another, and the next spelling walked through.
    #
    # THE PROPERTY, finally: **what the default LOOKS LIKE IS IRRELEVANT.** Any `${VAR:-…}`
    # is a knob a caller can turn, and a knob you have not pinned is a knob that can point
    # at the real machine. So pin EVERY knob. There is no classification left to get wrong.
    # `${1:-install}` is a POSITIONAL PARAMETER, not an environment variable — it cannot be
    # set through an env hash at all, so it is not a knob and cannot escape anything. That is
    # a fact about the shell language, not a judgement about how the default "looks", which is
    # the distinction that matters: we are excluding a NON-VARIABLE, not classifying a value.
    hatches = script.scan(/\$\{(\w+):-/).flatten.uniq.reject { |name| name.match?(/\A\d+\z/) }

    # PATH is read (`for dir in ${PATH:-}`), never written. It is pinned anyway rather than
    # special-cased: pinning costs nothing, and every exception carved into this list is a
    # place the next spelling can hide.
    pinned = %w[PROJECTS_DIR HOME PATH CODEX_REQUIREMENTS_PATH AGENT_DOCS_RUNTIME_ROOT
                AGENT_RUNTIME_RUBY_PATH_PREFIX AGENT_RUNTIME_ZPROFILE
                AGENT_ACTIVITY_BOARD_URL AGENT_INSIGHTS_BOARD_URL]

    # THE FLOOR. A subset assertion over an EMPTY set passes trivially — the exact way this
    # family of test fails open (see the same rule in sop_registry_docs_test.rb). If the scan
    # stops seeing the script's idiom, go RED rather than quietly assert nothing.
    assert_operator hatches.length, :>=, 5,
                    "the escape-hatch scan matched only #{hatches.length} `${VAR:-…}` override(s) in " \
                    "bin/install-agent-docs — it has at least 5. The scan has stopped seeing the script's " \
                    "idiom, so this test is now asserting NOTHING. Fix the scan; do not lower this floor."

    unpinned = hatches - pinned

    assert_empty unpinned,
                 "bin/install-agent-docs reads #{unpinned.inspect}, and this test does not pin " \
                 "#{unpinned.length == 1 ? "it" : "them"} — so running the installer under test could escape " \
                 "the sandbox and write to the real machine. Do NOT reason about whether the default 'looks " \
                 "absolute': computed (`$(…)`) and nested (`${…:-${…}}`) defaults resolve absolute at runtime " \
                 "and defeated two earlier versions of this very check. Pin it in the `env` hash, and add its " \
                 "destination to REAL_ROOT_DOCS."
  end

  # Guards the guard: every name in `pinned` must be one the scan can actually EMIT.
  # The previous version listed six names the regex could never produce — a reader would
  # believe seven destinations were held by the invariant when exactly one was.
  test "the pinned list contains no names the escape-hatch scan cannot produce" do
    script = Rails.root.join("bin/install-agent-docs").read
    # Scan for `${VAR:-` ANYWHERE, not line-anchored: the board URLs are NESTED hatches
    # (`X="${A:-${B:-default}}"`), so the inner var never appears at the start of a line.
    # A line-anchored scan here would call a REAL, reachable override a phantom.
    known = script.scan(/\$\{(\w+):-/).flatten.to_set
    # HOME and PROJECTS_DIR are pinned for real but are not `${X:-default}` hatches.
    declared = %w[CODEX_REQUIREMENTS_PATH AGENT_DOCS_RUNTIME_ROOT AGENT_RUNTIME_RUBY_PATH_PREFIX
                  AGENT_RUNTIME_ZPROFILE AGENT_ACTIVITY_BOARD_URL AGENT_INSIGHTS_BOARD_URL]

    phantom = declared.reject { |name| known.include?(name) }

    assert_empty phantom,
                 "these names are pinned by this test but bin/install-agent-docs never reads them: " \
                 "#{phantom.inspect}. Either the installer renamed them (and the pin is now dead, so a " \
                 "REAL destination may be unguarded), or the list is decoration. Coverage you cannot " \
                 "produce is coverage you do not have."
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
