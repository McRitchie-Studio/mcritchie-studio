require "test_helper"

# Release::LockOnlyConsumers decides which engine apps ride a release with no card:
# the ones whose `accepted` carries only the release tooling's lock bumps. On
# 2026-11-09 commercial-welding ran studio-engine 0.135.2 and alex-build 0.137.0 in
# production while their `accepted` held four bumps no release ever carried.
class Release::LockOnlyConsumersTest < ActiveSupport::TestCase
  M = Release::LockOnlyConsumers

  def bump(subject = "bump studio-engine 0.141.1", files: [ "Gemfile.lock" ], parents: [ "p1" ])
    { "sha" => "s#{subject.hash.abs}", "parents" => parents, "subject" => subject, "files" => files }
  end

  # --- parse_log ---

  test "parse_log reads the LOG_FORMAT records git prints, files and all" do
    text = "\x1eaaa\x1fppp\x1fbump studio-engine 0.141.1\n\nGemfile.lock\n" \
           "\x1ebbb\x1fqqq rrr\x1fMerge pull request #9\n\napp/models/x.rb\nGemfile\n"
    commits = M.parse_log(text)

    assert_equal 2, commits.size
    assert_equal({ "sha" => "aaa", "parents" => [ "ppp" ], "subject" => "bump studio-engine 0.141.1",
                   "files" => [ "Gemfile.lock" ] }, commits.first)
    assert_equal [ "qqq", "rrr" ], commits.last["parents"]
    assert_equal [ "app/models/x.rb", "Gemfile" ], commits.last["files"]
  end

  test "parse_log of an empty range is no commits" do
    assert_equal [], M.parse_log("")
    assert_equal [], M.parse_log(nil)
  end

  # --- lock_bump? / lock_only? ---

  test "each subject the release tooling writes is a lock bump" do
    [ "bump studio-engine 0.141.1",
      "bump studio-engine 0.141.1 for QA",
      "bump studio-engine 0.141.1, solana-studio 0.9.2",
      "bump studio-engine 0.142.0.rc1 for QA" ].each do |subject|
      assert M.lock_bump?(bump(subject)), subject
    end
  end

  test "engine migrations and the schema ride a lock bump" do
    files = [ "Gemfile.lock", "db/migrate/20261109101208_require_slugs.studio_engine.rb", "db/schema.rb" ]
    assert M.lock_bump?(bump(files: files))
  end

  test "a commit touching any other file is not a lock bump" do
    refute M.lock_bump?(bump(files: [ "Gemfile.lock", "app/models/user.rb" ]))
    refute M.lock_bump?(bump(files: [ "db/migrate/nested/x.rb" ]))
    refute M.lock_bump?(bump(files: []))
  end

  # Review 2026-11-09: a hand commit that copies the tool's subject must not carry
  # the app's OWN migration; only an engine-named copy rides.
  test "an app's own migration is not a lock bump, an engine-named one is" do
    refute M.lock_bump?(bump(files: [ "Gemfile.lock", "db/migrate/20261109000000_add_quotes.rb" ]))
    assert M.lock_bump?(bump(files: [ "Gemfile.lock", "db/migrate/20261109000000_add_x.solana_studio.rb" ]))
  end

  test "migrations lists the engine migrations the commits carry" do
    commits = [ bump(files: [ "Gemfile.lock", "db/migrate/1_a.studio_engine.rb", "db/schema.rb" ]),
                bump(files: [ "Gemfile.lock" ]) ]
    assert_equal [ "db/migrate/1_a.studio_engine.rb" ], M.migrations(commits)
    assert_includes M.riding_line("cw", commits), "1 engine migration(s): 1_a.studio_engine.rb"
    assert_includes M.riding_line("cw", [ bump ]), "no migrations"
  end

  # --- drop ---

  test "a dropped repo leaves the recorded set and is never recorded again" do
    meta = M.record({}, %w[commercial-welding rantly])
    meta = M.drop(meta, "rantly" => "production deploy failed: 503")

    assert_equal %w[commercial-welding], M.recorded(meta)
    assert_equal({ "rantly" => "production deploy failed: 503" }, M.dropped(meta))
    assert_equal %w[commercial-welding], M.recorded(M.record(meta, %w[rantly]))
    assert_equal [], M.extra_repos(meta, %w[commercial-welding])
  end

  test "the first drop reason stays" do
    meta = M.drop(M.drop({}, "rantly" => "first"), "rantly" => "second")
    assert_equal "first", M.dropped(meta)["rantly"]
  end

  test "a human subject or a merge commit is not a lock bump" do
    refute M.lock_bump?(bump("Bump the engine by hand"))
    refute M.lock_bump?(bump("bump studio-engine"))
    refute M.lock_bump?(bump(parents: %w[a b]))
  end

  test "lock_only? needs at least one commit, and every commit a lock bump" do
    assert M.lock_only?([ bump, bump("bump studio-engine 0.141.0") ])
    refute M.lock_only?([])
    refute M.lock_only?([ bump, bump("Fix the footer", files: [ "app/views/x.erb" ]) ])
  end

  # --- candidates ---

  test "candidates drop member repos, other trains' repos and held repos" do
    apps = %w[mcritchie-studio commercial-welding alex-build moms-app]

    assert_equal %w[commercial-welding alex-build moms-app],
                 M.candidates(engine_apps: apps, member_repos: [ "mcritchie-studio" ])
    assert_equal %w[alex-build],
                 M.candidates(engine_apps: apps, member_repos: [ "mcritchie-studio" ],
                              train_repos: %w[mcritchie-studio alex-build moms-app],
                              held_repos: [ { "repo" => "moms-app", "train" => "x", "slug" => "rel" } ])
  end

  # --- record / recorded / extra_repos ---

  test "record unions into the release metadata and keeps every other key" do
    meta = M.record({ "qa_shas" => { "a" => "1" }, M::LOCK_ONLY_KEY => [ "alex-build" ] },
                    %w[commercial-welding alex-build])

    assert_equal %w[alex-build commercial-welding], meta[M::LOCK_ONLY_KEY]
    assert_equal({ "a" => "1" }, meta["qa_shas"])
  end

  test "extra_repos skips a recorded repo a member already names" do
    meta = { M::LOCK_ONLY_KEY => %w[commercial-welding alex-build] }

    assert_equal %w[alex-build], M.extra_repos(meta, %w[mcritchie-studio commercial-welding])
    assert_equal [], M.extra_repos({}, %w[mcritchie-studio])
    assert_equal [], M.extra_repos(nil, [])
  end

  # --- lag (bin/release status) ---

  test "an app a minor or more behind lags; a patch behind does not" do
    live = { "commercial-welding" => "0.135.2", "alex-build" => "0.137.0",
             "moms-app" => "0.141.0", "mcritchie-studio" => "0.141.1" }

    assert_equal [ { "repo" => "alex-build", "live" => "0.137.0", "reference" => "0.141.1" },
                   { "repo" => "commercial-welding", "live" => "0.135.2", "reference" => "0.141.1" } ],
                 M.lagging(live, "0.141.1")
  end

  test "a major behind lags; an app ahead does not" do
    assert_equal [ "a" ], M.lagging({ "a" => "0.9.9", "b" => "1.1.0" }, "1.0.0").map { |r| r["repo"] }
  end

  test "status lines name each lagging app, what accepted carries, and the unreadable ones" do
    lines = M.status_lines(gem_name: "studio-engine", reference: "0.141.1",
                           live_locks: { "commercial-welding" => "0.135.2", "moms-app" => "0.141.0", "voicebox" => nil },
                           accepted_locks: { "commercial-welding" => "0.141.1" })

    assert_equal 2, lines.size
    assert_match(/\ALAGS commercial-welding: production locks studio-engine 0.135.2, the last shipped is 0.141.1/, lines[0])
    assert_includes lines[0], "`accepted` locks 0.141.1; the next `bin/release prepare` carries it"
    assert_match(/cannot confirm voicebox/, lines[1])
  end

  test "status says so when nothing lags, and when the reference is unreadable" do
    assert_equal [ "every engine app's production is within one minor of studio-engine 0.141.1" ],
                 M.status_lines(gem_name: "studio-engine", reference: "0.141.1", live_locks: { "a" => "0.141.0" })
    assert_match(/cannot confirm the shipped version/,
                 M.status_lines(gem_name: "studio-engine", reference: "", live_locks: { "a" => "0.1.0" }).first)
  end

  test "an accepted lock still behind says it needs a bump" do
    line = M.status_lines(gem_name: "studio-engine", reference: "0.141.1",
                          live_locks: { "a" => "0.130.0" }, accepted_locks: { "a" => "0.130.0" }).first
    assert_includes line, "needs a lock bump"
  end

  # --- what the release says about its lock-only apps (task lock-only-drop-follow-ups) ---

  test "[unit] notes_lines name the apps that rode and each drop with its reason" do
    meta = M.drop({ M::LOCK_ONLY_KEY => %w[commercial-welding rantly] }, "rantly" => "production deploy failed: smoke /up 503")
    lines = M.notes_lines(meta)

    assert_equal "Lock bumps only (no card): commercial-welding", lines.first
    assert_includes lines.last, "Dropped (lock bumps only, not shipped by this release): rantly — production deploy failed"
    assert_equal [], M.notes_lines({})
  end

  test "[unit] the seal note names the drops, or nothing" do
    assert_equal "lock-only dropped, not shipped: rantly, alex-build", M.seal_note("rantly" => "x", "alex-build" => "y")
    assert_nil M.seal_note({})
  end

  test "[unit] a production-stage drop is visible in status" do
    lines = M.drop_status_lines([ { "slug" => "rel-x", "dropped" => { "rantly" => "production deploy failed: smoke" } } ])

    assert_equal 1, lines.size
    assert_includes lines.first, "DROPPED rantly from rel-x: production deploy failed: smoke"
    assert_includes lines.first, "the next sweep carries it again"
    assert_equal [], M.drop_status_lines(nil)
  end
end
