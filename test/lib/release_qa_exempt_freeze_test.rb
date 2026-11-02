# frozen_string_literal: true

# QA-EXEMPT REPOS ARE FROZEN TOO (task faster-steadier-production-ship, part 3a). rantly and
# moms-app have no QA environment (config/qa_environments.yml), so `prepare` skips them before a
# qa_sha, and the ship froze each at origin/release LIVE (frozen_sha_for's fallback). On a
# RESUMED ship that head is the final-gem re-lock while QA'd repos freeze at the candidate lock,
# so the gem candidate preflight refuses. The hand fix was Release::Conductor.record_qa_shas.
# History: task faster-steadier-production-ship.

require_relative "release_cli_harness"

class ReleaseQaExemptFreezeTest < ReleaseCliHarness
  RC_LOCK = "1" * 40   # origin/release at prepare: the candidate lock bump
  RELOCK  = "2" * 40   # origin/release after the first ship attempt pushed the final re-lock
  HUB_QA  = "3" * 40

  RC_LOCKFILE    = "GEM\n  specs:\n    studio-engine (0.114.1.rc1)\n"
  FINAL_LOCKFILE = "GEM\n  specs:\n    studio-engine (0.114.1)\n"

  # [unit] THE FIX, at prepare: a QA-exempt app's origin/release head is recorded.
  def test_prepare_records_a_qa_sha_for_a_qa_exempt_repo
    setup = SWEEP_FLOW_STUB + <<~RUBY
      alias sweep_conductor conductor
      def conductor(ruby, read_only: false)
        if ruby.include?("sweep!")
          return { "slug" => "rel-sweep", "state" => "assembling", "swept" => %w[task-accepted], "repos" => [
            { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
              "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "task-accepted", "branch" => "feat/n" }] },
            { "repo" => "rantly", "kind" => "app", "release_branch" => "release",
              "qa_app" => "rantly", "members" => [{ "slug" => "task-rantly", "branch" => "feat/r" }] }
          ] }
        end
        $stdout.puts("QA-SHAS-CALL " + ruby) if ruby.include?("record_qa_shas")
        sweep_conductor(ruby, read_only: read_only)
      end
      alias sweep_sh sh
      def sh(*a, **k)
        return [#{RC_LOCK.inspect}, true] if a[0] == "git" && a.include?("rev-parse") && a.include?("origin/release")
        sweep_sh(*a, **k)
      end
    RUBY
    out = run_cli(["--yes"], call: "prepare", setup: setup)

    assert_includes out, "rantly: no QA environment registered", "rantly is QA-exempt in this fixture: #{out}"
    call = out.lines.find { |l| l.start_with?("QA-SHAS-CALL") }
    assert call, "prepare must record qa_shas: #{out}"
    assert_includes call, %("rantly" => #{RC_LOCK.inspect}).delete(" "),
                    "a QA-exempt repo is frozen at its prepare-time origin/release head"
  end

  # The world a RESUMED ship reads: origin/release in rantly already carries the re-lock.
  def resume_world(qa_shas)
    <<~RUBY
      def git_capture(*a)
        joined = a.join(" ")
        return [#{RELOCK.inspect} + "\\n", true] if joined.include?("rev-parse origin/release")
        if a.include?("show")
          spec = a.last.to_s
          return [(spec.start_with?(#{RELOCK.inspect}) ? #{FINAL_LOCKFILE.inspect} : #{RC_LOCKFILE.inspect}), true]
        end
        return ["", true] if a.include?("tag")
        ["", false]
      end
      def gem_version_for(*) = "0.114.1"
      $qa_shas = #{qa_shas.inspect}
      $groups = [{ "repo" => "studio-engine", "kind" => "gem" }]
      $apps = [{ "repo" => "mcritchie-studio", "kind" => "app" }, { "repo" => "rantly", "kind" => "app" }]
      $ship_sha = {}
      ($groups + $apps).each { |g| $ship_sha[g["repo"]] = frozen_sha_for(g["repo"], $qa_shas) }
    RUBY
  end

  def candidate_problems(qa_shas)
    run_cli([], setup: resume_world(qa_shas),
                call: %(_c, problems = ship_gem_candidates($groups, $apps, $ship_sha); puts "PROBLEMS=\#{problems.inspect}"))
  end

  # [unit] THE FAILURE, reproduced: no qa_sha for rantly → it freezes at the re-lock →
  # the candidate preflight refuses the resumed ship.
  def test_a_resumed_ship_without_the_exempt_repos_qa_sha_refuses_at_the_candidate_preflight
    out = candidate_problems({ "mcritchie-studio" => HUB_QA, "studio-engine" => HUB_QA })

    assert_includes out, "some consumers lock 0.114.1 and others a candidate of it", out
  end

  # [unit] ...and with the qa_sha prepare now records, the same resume passes.
  def test_a_resumed_ship_with_the_exempt_repos_qa_sha_passes_the_candidate_preflight
    out = candidate_problems({ "mcritchie-studio" => HUB_QA, "studio-engine" => HUB_QA, "rantly" => RC_LOCK })

    assert_includes out, "PROBLEMS=[]", out
  end

  # [unit] THE SHIP-SIDE BACKFILL: a release prepared by older tooling has no
  # rantly qa_sha; the ship records the live-resolved SHA before anything moves, so
  # its own resume reads it from the record.
  def test_the_ship_backfills_a_never_frozen_repo_before_anything_moves
    setup = <<~RUBY
      $calls = []
      def conductor(ruby, read_only: false)
        $calls << ruby
        {}
      end
    RUBY
    call = <<~CALL
      m = backfill_qa_shas!("rel-x", { "mcritchie-studio" => #{HUB_QA.inspect} },
                            { "mcritchie-studio" => #{HUB_QA.inspect}, "rantly" => #{RC_LOCK.inspect} })
      puts "RECORDED=\#{m.keys.inspect}"
      puts "CALLS=\#{$calls.size}"
      puts $calls.first
    CALL
    out = run_cli([], setup: setup, call: call)

    assert_includes out, 'RECORDED=["rantly"]', "only the never-frozen repo is backfilled: #{out}"
    assert_includes out, "CALLS=1"
    assert_includes out, RC_LOCK
    assert_includes out, %(slug: "rel-x")
  end

  def test_the_backfill_records_nothing_when_every_repo_was_frozen
    setup = "$calls = []\ndef conductor(ruby, read_only: false) = ($calls << ruby; {})\n"
    out = run_cli([], setup: setup,
                      call: %(m = backfill_qa_shas!("rel-x", { "rantly" => #{RC_LOCK.inspect} }, { "rantly" => #{RC_LOCK.inspect} }); puts "N=\#{$calls.size} M=\#{m.inspect}"))

    assert_includes out, "N=0 M={}"
  end
end
