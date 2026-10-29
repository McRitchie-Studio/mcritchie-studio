# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# Release::MemberContainment: a member is stamped `shipped` only when its own commit
# is an ancestor of the SHA its release pushed to `main`. The 2026-10-28 incident:
# moms-app-mail-from-team (merge d80098f) was stamped shipped by a release whose
# moms-app main push (eb7655f) did not contain it.
class Release::MemberContainmentTest < ActiveSupport::TestCase
  MOMS = "moms-app"
  HUB  = "mcritchie-studio"

  def group(repo, *slugs)
    { "repo" => repo, "members" => slugs.map { |slug| { "slug" => slug } } }
  end

  # --- the pure rule ---------------------------------------------------------

  test "[unit] ship member stamping refuses a merge not contained in main" do
    holds = Release::MemberContainment.holds(
      groups: [ group(MOMS, "moms-app-mail-from-team") ],
      main_shas: { MOMS => "eb7655f000" },
      code_shas: ->(_repo, _member) { [ "d80098f000", "headsha000" ] },
      contains: ->(_repo, _sha, _main) { :refuted }
    )

    note = holds.fetch("moms-app-mail-from-team")
    assert_includes note, "d80098f", "the note names the missing commit"
    assert_includes note, "eb7655f", "and the main it is missing from"
    assert_match(/not stamped shipped/, note)
  end

  test "[unit] a member whose merge commit is in main is not held" do
    holds = Release::MemberContainment.holds(
      groups: [ group(MOMS, "contained") ],
      main_shas: { MOMS => "main" },
      code_shas: ->(_repo, _member) { [ "merge", "head" ] },
      contains: ->(_repo, sha, _main) { sha == "merge" ? :affirmed : :refuted }
    )

    assert_empty holds
  end

  test "[unit] the PR head being contained is enough (a squash leaves the head off main)" do
    holds = Release::MemberContainment.holds(
      groups: [ group(MOMS, "squashed") ],
      main_shas: { MOMS => "main" },
      code_shas: ->(_repo, _member) { [ "merge", "head" ] },
      contains: ->(_repo, sha, _main) { sha == "head" ? :affirmed : :refuted }
    )

    assert_empty holds
  end

  test "[unit] an unreadable member is HELD, not waved through" do
    unknown = Release::MemberContainment.holds(
      groups: [ group(MOMS, "unreadable") ],
      main_shas: { MOMS => "main" },
      code_shas: ->(_repo, _member) { [ "merge" ] },
      contains: ->(_repo, _sha, _main) { :unknown }
    )
    no_pr = Release::MemberContainment.holds(
      groups: [ group(MOMS, "no-pr") ],
      main_shas: { MOMS => "main" },
      code_shas: ->(_repo, _member) { [] },
      contains: ->(*) { flunk "nothing to ask" }
    )
    raised = Release::MemberContainment.holds(
      groups: [ group(MOMS, "gh-down") ],
      main_shas: { MOMS => "main" },
      code_shas: ->(_repo, _member) { raise "Bad credentials" },
      contains: ->(*) { flunk "nothing to ask" }
    )

    assert_match(/could not prove/, unknown.fetch("unreadable"))
    assert_match(/no merge commit or PR head/, no_pr.fetch("no-pr"))
    assert_match(/Bad credentials/, raised.fetch("gh-down"))
  end

  test "[unit] a repo with no main SHA is left to MemberEvidence" do
    holds = Release::MemberContainment.holds(
      groups: [ group(MOMS, "no-evidence") ],
      main_shas: {},
      code_shas: ->(*) { flunk "never read" },
      contains: ->(*) { flunk "never asked" }
    )

    assert_empty holds
  end

  test "[unit] a multi-repo member is held for the repo it missed and named once" do
    groups = [ group(HUB, "two-repo"), group(MOMS, "two-repo") ]
    holds = Release::MemberContainment.holds(
      groups: groups,
      main_shas: { HUB => "hubmain", MOMS => "momsmain" },
      code_shas: ->(repo, _member) { [ "#{repo}-merge" ] },
      contains: ->(repo, _sha, _main) { repo == HUB ? :affirmed : :refuted }
    )

    assert_equal [ "two-repo" ], holds.keys
    assert_includes holds["two-repo"], "moms-app commit moms-ap"
    refute_includes holds["two-repo"], "mcritchie-studio commit"
  end

  test "[unit] shas_from_pr reads the merge commit first, then the head" do
    json = { "mergeCommit" => { "oid" => "abc" }, "headRefOid" => "def" }

    assert_equal %w[abc def], Release::MemberContainment.shas_from_pr(json)
    assert_equal %w[def], Release::MemberContainment.shas_from_pr("mergeCommit" => nil, "headRefOid" => "def")
    assert_equal [], Release::MemberContainment.shas_from_pr(nil)
  end

  test "[unit] git_verdict answers unknown for a fault, never refuted" do
    # merge-base exiting 128 (a fault) must not masquerade as "not an ancestor".
    runner = lambda do |_path, *args|
      args.first == "merge-base" ? [ "fatal", 128 ] : [ "", 0 ]
    end

    assert_equal :unknown, Release::MemberContainment.git_verdict(path: "/x", sha: "a", main_sha: "b", runner: runner)
  end

  test "[unit] git_verdict fetches a missing sha once before giving up" do
    calls = []
    runner = lambda do |_path, *args|
      calls << args.first
      args.first == "rev-parse" && args.include?("missing^{commit}") ? [ "", 1 ] : [ "", 0 ]
    end

    assert_equal :unknown, Release::MemberContainment.git_verdict(path: "/x", sha: "missing", main_sha: "b", runner: runner)
    assert_includes calls, "fetch"
  end

  # --- against a real git history -------------------------------------------

  # main at `old`; `release` one merge ahead at `merged`. The incident's geometry.
  def with_ladder_repo
    Dir.mktmpdir("containment-") do |dir|
      git = ->(*args) { out, st = Open3.capture2e("git", "-C", dir, *args); assert st.success?, out; out.strip }
      git.call("init", "-q", "-b", "main")
      git.call("config", "user.email", "t@example.com")
      git.call("config", "user.name", "t")
      git.call("commit", "-q", "--allow-empty", "-m", "base")
      old = git.call("rev-parse", "HEAD")
      git.call("checkout", "-q", "-b", "feat/mail")
      git.call("commit", "-q", "--allow-empty", "-m", "mail from team")
      head = git.call("rev-parse", "HEAD")
      git.call("checkout", "-q", "-b", "release", "main")
      git.call("merge", "-q", "--no-ff", "-m", "merge mail", "feat/mail")
      merged = git.call("rev-parse", "HEAD")
      yield dir, old: old, head: head, merged: merged
    end
  end

  test "[integration] git_verdict refutes a merge that main does not contain and affirms one it does" do
    with_ladder_repo do |dir, shas|
      assert_equal :refuted, Release::MemberContainment.git_verdict(path: dir, sha: shas[:merged], main_sha: shas[:old])
      assert_equal :affirmed, Release::MemberContainment.git_verdict(path: dir, sha: shas[:merged], main_sha: shas[:merged])
      assert_equal :affirmed, Release::MemberContainment.git_verdict(path: dir, sha: shas[:head], main_sha: shas[:merged])
    end
  end

  # THE TWO-RELEASE RACE. A release whose moms-app main push is the OLD tip (the
  # concurrent ship's eb7655f) carries a member whose merge (d80098f) landed on
  # `release` after that tip. The pipeline records moms-app as shipped — it did
  # move — so MemberEvidence alone passes the member. Containment must hold it,
  # and the neighbour whose code IS in that main must still ship.
  test "[integration] a two-release race leaves the late member unshipped" do
    with_ladder_repo do |dir, shas|
      late = Task.create!(title: "moms app mail from team", stage: "reviewed",
                          metadata: { "devops" => { "shape" => "backend", "repositories" => [ MOMS ] } })
      early = Task.create!(title: "moms app earlier fix", stage: "reviewed",
                           metadata: { "devops" => { "shape" => "backend", "repositories" => [ MOMS ] } })
      release = Release::Conductor.sweep!(late)
      Release::Conductor.sweep!(early)
      Release::Conductor.record_qa_shas(release: release.reload, shas: { MOMS => shas[:merged] })
      Release::Conductor.qa_green!(release.reload)
      assert_equal %w[assembled assembled], [ late.reload.stage, early.reload.stage ]

      # The concurrent ship pushed main to the OLD tip, and recorded it.
      main_shas = { MOMS => shas[:old] }
      Release::Conductor.record_shipped_shas(release: release.reload, shas: main_shas)
      code = { late.slug => [ shas[:merged], shas[:head] ], early.slug => [ shas[:old] ] }
      holds = Release::MemberContainment.holds(
        groups: Release::Conductor.repo_plan(release.reload).map(&:deep_stringify_keys),
        main_shas: main_shas,
        code_shas: ->(_repo, member) { code.fetch(member["slug"]) },
        contains: ->(_repo, sha, main) { Release::MemberContainment.git_verdict(path: dir, sha: sha, main_sha: main) }
      )
      assert_equal [ late.slug ], holds.keys

      Release::Conductor.record_ship_holds(release: release.reload, holds: holds)
      Release::Conductor.ship!(release: release.reload, deployed_sha: shas[:old])

      late.reload
      assert_equal "assembled", late.stage, "its code missed main, so it keeps its prior stage"
      refute_equal Task::MERGED_MAIN, late.merged, "and never claims its code is on main"
      assert_equal "shipped", early.reload.stage, "a contained neighbour still ships"

      note = Activity.where(task_slug: late.slug, activity_type: "comment").sole
      assert_includes note.description, shas[:merged][0, 7], "the note names the missing commit"
      assert_equal release.slug, note.metadata["release"]

      # A resumed record step with the same verdict posts no second note …
      Release::Conductor.ship!(release: release.reload, deployed_sha: shas[:old])
      assert_equal 1, Activity.where(task_slug: late.slug, activity_type: "comment").count
      assert_equal "assembled", late.reload.stage

      # … and a finalize that finds the code contained clears the hold and ships it.
      Release::Conductor.record_ship_holds(release: release.reload, holds: {})
      Release::Conductor.ship!(release: release.reload, deployed_sha: shas[:merged])
      assert_equal "shipped", late.reload.stage
    end
  end
  # A tripwire, not the proof (the race test above is): both record steps that can
  # stamp members shipped — the live ship and finalize — must write the holds in
  # the same conductor call, before ship! reads them.
  test "[unit] bin/release records the containment holds before every ship! record" do
    src = Rails.root.join("bin", "release.rb").read
    calls = src.scan(/^.*Release::Conductor\.ship!\(release: r,.*$/)
    assert_equal 2, calls.size, "ship and finalize each record members once"
    pairs = src.scan(/record_shipped_shas\(release: r.*\n(.*)\n(.*Conductor\.ship!\(release: r)/)
    assert_equal 2, pairs.size, "each ship! record follows shipped_shas and one line between"
    pairs.each do |holds_line, _ship|
      assert_includes holds_line, "record_ship_holds(release: r, holds: \#{ship_holds.inspect}, checked: \#{ship_checked.inspect})"
    end
    assert_equal 2, src.scan("ship_holds = ship_containment_holds(").size
  end

  # THE INCIDENT'S OWN PATH (Carl, activity-21399). moms-app-mail-from-team was
  # swept onto the release AFTER the ship read its plan: Release#add reopened it
  # mid-ship. The check never saw the member, so it must fail closed — held as
  # unchecked — rather than be stamped because nobody objected.
  test "[integration] a member swept in after the holds are computed stays unshipped" do
    early = Task.create!(title: "moms app checked fix", stage: "reviewed",
                         metadata: { "devops" => { "shape" => "backend", "repositories" => [ MOMS ] } })
    release = Release::Conductor.sweep!(early)
    Release::Conductor.record_qa_shas(release: release.reload, shas: { MOMS => "frozen" })
    Release::Conductor.qa_green!(release.reload)
    Release::Conductor.record_shipped_shas(release: release.reload, shas: { MOMS => "relock" })

    # The CLI's snapshot: one member, contained, no holds.
    plan = Release::Conductor.repo_plan(release.reload).map(&:deep_stringify_keys)
    holds = Release::MemberContainment.holds(groups: plan, main_shas: { MOMS => "relock" },
                                             code_shas: ->(*) { [ "in" ] }, contains: ->(*) { :affirmed })
    assert_empty holds

    # The late sweep lands while the ship deploys.
    late = Task.create!(title: "moms app mail from team late", stage: "reviewed",
                        metadata: { "devops" => { "shape" => "backend", "repositories" => [ MOMS ] } })
    Release::Conductor.sweep!(late)
    late.reload.update!(stage: "assembled")
    assert_equal release.slug, late.release_slug, "it joined the release being shipped"

    Release::Conductor.record_ship_holds(release: release.reload, holds: holds,
                                         checked: plan.flat_map { |g| g["members"].map { |m| m["slug"] } })
    Release::Conductor.ship!(release: release.reload, deployed_sha: "relock")

    assert_equal "shipped", early.reload.stage, "the checked member ships"
    assert_equal "assembled", late.reload.stage, "the unchecked late joiner does NOT"
    note = Activity.where(task_slug: late.slug, activity_type: "comment").sole
    assert_match(/after the ship's containment check/, note.description)

    # finalize's fresh snapshot covers it and, once contained, it ships.
    Release::Conductor.record_ship_holds(release: release.reload, holds: {}, checked: [ early.slug, late.slug ])
    Release::Conductor.ship!(release: release.reload, deployed_sha: "relock")
    assert_equal "shipped", late.reload.stage
  end

  test "[unit] a release with no recorded checked list holds nothing extra (model-driven path)" do
    task = Task.create!(title: "model driven member", stage: "reviewed",
                        metadata: { "devops" => { "shape" => "backend", "repositories" => [ MOMS ] } })
    release = Release::Conductor.sweep!(task)
    Release::Conductor.qa_green!(release.reload)
    Release::Conductor.ship!(release: release.reload, deployed_sha: "x")

    assert_equal "shipped", task.reload.stage
  end

  test "[unit] a gem member in an app group is not asked (it would hold unknown forever)" do
    holds = Release::MemberContainment.holds(
      groups: [ { "repo" => MOMS, "members" => [ { "slug" => "engine-bump", "kind" => "gem" } ] } ],
      main_shas: { MOMS => "main" },
      code_shas: ->(*) { flunk "a gem member has no PR here" },
      contains: ->(*) { flunk "never asked" }
    )

    assert_empty holds
  end

  test "[unit] a git call past its deadline is killed and reads unknown" do
    Dir.mktmpdir("containment-deadline-") do |dir|
      Open3.capture2e("git", "-C", dir, "init", "-q")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _out, status = Release::MemberContainment.git(dir, "-c", "alias.hang=!sleep 30", "hang", deadline: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal(-1, status, "a killed call is a fault, never a clean 0 or 1")
      assert_operator elapsed, :<, 10, "the deadline, not the hang, ended it"
      hung = ->(_path, *args) { args.first == "merge-base" ? Release::MemberContainment.git(dir, "-c", "alias.hang=!sleep 30", "hang", deadline: 1) : [ "", 0 ] }
      assert_equal :unknown, Release::MemberContainment.git_verdict(path: dir, sha: "a", main_sha: "b", runner: hung)
    end
  end

  test "[unit] bin/release bounds the containment git reads and records the checked slugs" do
    src = Rails.root.join("bin", "release.rb").read
    assert_includes src, "main_sha: main_sha, deadline: read_deadline)"
    assert_equal 2, src.scan("ship_checked = ship_checked_slugs(repos)").size
    assert_equal 2, src.scan('checked: #{ship_checked.inspect}); "').size
    assert_includes src, "GhAuthRetry.auth_failure?(out)", "an expired token is re-minted, not read as unknown"
  end
end
