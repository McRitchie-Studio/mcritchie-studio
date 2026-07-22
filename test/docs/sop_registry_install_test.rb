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
#
# ⛔ AND WE PROVE IT ATTRIBUTABLY, NOT DIFFERENTIALLY. The first cut fingerprinted the
# operator's REAL ~/.claude/skills and ~/.codex/skills before/after the run and asserted
# the digest was unchanged. But the premise "nothing else writes these directories" is
# FALSE — the Claude and Codex RUNTIMES write them too, so a digest could change for
# reasons wholly unrelated to the code under test and false-redden the suite. Redirecting
# the fingerprint at a temp dir would just delete the coverage: the digest existed to
# catch a write that ESCAPES the env pins. So instead the installer has a dry-run
# `manifest` mode that SELF-REPORTS every absolute path it would write, and the test
# asserts not one escapes the sandbox — a deterministic property that owes nothing to
# what the runtime did to the real dirs meanwhile.
class SopRegistryInstallTest < ActiveSupport::TestCase
  test "install-agent-docs generates AGENTS.md and CLAUDE.md that can resolve clean-up" do
    Dir.mktmpdir("sop-install") do |sandbox|
      projects = File.join(sandbox, "projects")
      home     = File.join(sandbox, "home")
      FileUtils.mkdir_p([projects, home, File.join(sandbox, "tmp")]) # tmp: the pinned TMPDIR mktemp resolves
      env = sandbox_env(sandbox, projects, home)

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

      # ATTRIBUTABLE sandbox proof (replaces the differential digest of the runtime-
      # written skills dirs). Ask the installer, in dry-run manifest mode under the SAME
      # pinned env, for every absolute path it WOULD write, and assert not one escapes
      # the sandbox. Self-reported and deterministic — it does not read the real dirs.
      man_out, man_status = Open3.capture2e(env, Rails.root.join("bin/install-agent-docs").to_s, "manifest",
                                            chdir: Rails.root.to_s)
      assert man_status.success?, "install-agent-docs manifest failed:\n#{man_out}"
      targets = manifest_targets(man_out)

      # THE FLOOR. A "nothing escaped" assertion over an EMPTY manifest passes trivially —
      # the way this family of test fails open. If the dry run stops reporting writes, go
      # RED rather than quietly assert nothing. (The installer writes ~13 destinations.)
      assert_operator targets.length, :>=, 5,
                      "the manifest listed only #{targets.length} write destination(s) — the dry run has " \
                      "stopped reporting the installer's writes, so this proof now asserts NOTHING. Fix the " \
                      "manifest (a write site missing its note_write), do not lower this floor."

      escapes = targets.reject { |path| inside?(sandbox, path) }
      assert_empty escapes,
                   "install-agent-docs would write OUTSIDE its sandbox: #{escapes.inspect}. Every destination " \
                   "must derive from a pinned knob (HOME / PROJECTS_DIR / CODEX_REQUIREMENTS_PATH / …); an " \
                   "absolute path here is a hatch that escapes the pins — the exact failure this test exists " \
                   "to catch. Pin the knob in sandbox_env, or fix the installer to route the write through one."
    end
  end

  # MUTATION PROOF: the escape check is NOT inert. Point one destination knob at an
  # absolute path OUTSIDE the sandbox — the shape of a mis-sandboxed write the old
  # differential digest used to catch — and the manifest must surface it as an escape,
  # so the assertion above would go RED. This guard was defeated twice before; a
  # replacement that cannot fail on a real escape is worthless.
  test "the manifest escape check goes red on a destination that leaves the sandbox" do
    Dir.mktmpdir("sop-escape-in") do |sandbox|
      Dir.mktmpdir("sop-escape-out") do |outside|
        projects = File.join(sandbox, "projects")
        home     = File.join(sandbox, "home")
        FileUtils.mkdir_p([projects, home])
        escape_zprofile = File.join(outside, ".zprofile")
        env = sandbox_env(sandbox, projects, home).merge("AGENT_RUNTIME_ZPROFILE" => escape_zprofile)

        man_out, man_status = Open3.capture2e(env, Rails.root.join("bin/install-agent-docs").to_s, "manifest",
                                              chdir: Rails.root.to_s)
        assert man_status.success?, man_out
        targets = manifest_targets(man_out)
        escapes = targets.reject { |path| inside?(sandbox, path) }

        assert_includes escapes, escape_zprofile,
                        "a destination pointed OUTSIDE the sandbox did NOT surface as an escape — the manifest " \
                        "check is inert and would wave a mis-sandboxed write straight through to the real machine"
      end
    end
  end

  # THE DURABLE HALF. The manifest check above proves that whatever the installer WOULD
  # write lands in the sandbox — but only for the knobs `sandbox_env` actually pins. A
  # knob it forgot to pin would default to the REAL machine and escape the manifest's
  # "all under sandbox" assertion unseen. So ALSO assert the POSITIVE invariant: every
  # ABSOLUTE default the installer can be pointed at must be pinned by this test.
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

    # COUPLED to the authority — `sandbox_env` is the exact env this test runs the installer
    # under, so derive the expected pin set FROM it (a hardcoded copy can silently drift from
    # what the manifest test actually pins). A knob added to the installer but not to
    # sandbox_env then goes RED here, not silently unpinned. PATH is read-only
    # (`for dir in ${PATH:-}`), never a write target, so it is the one hatch sandbox_env
    # need not pin — added explicitly.
    pinned = sandbox_env("/s", "/p", "/h").keys + %w[PATH]

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
                 "and defeated two earlier versions of this very check. Pin it in `sandbox_env` so the manifest " \
                 "check resolves its destination inside the sandbox."
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
    # Coupled to sandbox_env too: every ${VAR:-} hatch it pins must be one the scan can
    # produce, or the pin is dead. HOME is read as `$HOME` and the session neutralizers are
    # not write knobs — they are the sandbox_env pins that legitimately are NOT `${X:-}`
    # hatches, so they are excluded here rather than flagged phantom.
    non_hatch_pins = %w[HOME AGENT_SESSION_ID ATOMIC_CAPTURE_URL]
    declared = sandbox_env("/s", "/p", "/h").keys - non_hatch_pins

    phantom = declared.reject { |name| known.include?(name) }

    assert_empty phantom,
                 "these names are pinned by this test but bin/install-agent-docs never reads them: " \
                 "#{phantom.inspect}. Either the installer renamed them (and the pin is now dead, so a " \
                 "REAL destination may be unguarded), or the list is decoration. Coverage you cannot " \
                 "produce is coverage you do not have."
  end

  # The env that pins EVERY write destination of bin/install-agent-docs into `sandbox`.
  # The positive-invariant test above asserts this hash pins every ${VAR:-…} knob the
  # script reads, so a new destination someone adds is caught by a red test, not a
  # reviewer. (PATH is left inherited — the installer only READS it.)
  def sandbox_env(sandbox, projects, home)
    {
      "PROJECTS_DIR" => projects,
      "HOME" => home,
      "CODEX_REQUIREMENTS_PATH" => File.join(sandbox, "etc-codex", "requirements.toml"),
      "AGENT_DOCS_RUNTIME_ROOT" => File.join(sandbox, "runtime"),
      "AGENT_RUNTIME_ZPROFILE" => File.join(home, ".zprofile"),
      "AGENT_RUNTIME_RUBY_PATH_PREFIX" => File.join(sandbox, "ruby-bin"),
      # The installer's many jq blocks scratch through `mktemp`, which resolves TMPDIR —
      # pin it into the sandbox too so those transient writes can't land on the real
      # machine, and so the manifest's `${TMPDIR:-/tmp}` destination proves out inside.
      "TMPDIR" => File.join(sandbox, "tmp"),
      # Never let a test inherit the live session's identity or board.
      "AGENT_SESSION_ID" => nil,
      "ATOMIC_CAPTURE_URL" => nil,
      "AGENT_ACTIVITY_BOARD_URL" => "http://localhost:0",
      "AGENT_INSIGHTS_BOARD_URL" => "http://localhost:0"
    }
  end

  # The absolute destinations the installer SELF-REPORTED it would write, one per
  # "WRITE\t<abs>" line of its dry-run manifest mode.
  def manifest_targets(out)
    out.lines.filter_map do |line|
      tag, path = line.chomp.split("\t", 2)
      path if tag == "WRITE" && !path.to_s.empty?
    end
  end

  # Is `path` inside `root`? Compared on a path-segment boundary so a sibling like
  # "<root>-evil" is NOT counted inside "<root>".
  def inside?(root, path)
    root = File.expand_path(root)
    path = File.expand_path(path)
    path == root || path.start_with?("#{root}/")
  end
end
