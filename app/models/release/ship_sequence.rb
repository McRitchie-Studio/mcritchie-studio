class Release
  # Pure decision logic for the multi-repo `bin/release ship` ("Run Deployment").
  #
  # Like Release::GemfileRepin this is deliberately IO-free: no git, no gem push,
  # no bundle, no network. It takes plans/listings/text in and returns
  # symbols/booleans/arrays out, so the git + gem + bundle orchestration stays in
  # bin/release and ALL the sequencing/version/ordering decisions stay here, unit
  # tested. (bin/release `require`s this file directly — it has no Rails deps.)
  #
  # The five decisions a multi-repo ship turns on:
  #   * which prod-deploy adapter handles a repo            (strategy_handler)
  #   * the hub-before-satellites app order                 (ordered_app_groups)
  #   * which of a consumer's gems still need re-pinning     (gems_to_repin)
  #   * whether a gem version must still be published        (publish_needed?)
  #   * the QA-frozen SHA to ship for a repo (or fall back)  (frozen_sha)
  # Plus the PREPARE-side gem decisions (the producer-first publish moved up in
  # front of the pre-QA gate — publish-gems-before-qa):
  #   * what a consumer Gemfile needs for a published gem    (consumer_bump_action)
  #   * the stranded-work guard on an unbumped gem repo      (stranded_gem_work?)
  module ShipSequence
    module_function

    # The ecosystem hub. Release::Ordering already sorts gems before apps, but NOT
    # the hub before the satellites — the hub (SSO/source-of-truth) ships first so
    # a satellite never goes live against a hub that hasn't caught up.
    HUB = "mcritchie-studio"

    # The prod_deploy `strategy` → the bin/release handler that runs it. Raises on
    # an unregistered strategy so a typo in config/release_repos.yml fails loudly
    # at ship time rather than silently skipping a repo's deploy.
    #   * git_push_heroku — the conductor ref-pushes the frozen SHA to a Heroku
    #     git remote and smokes /up itself (rolio).
    #   * repo_script     — the conductor shells out to the repo's own deploy
    #     script in a ship workspace (turf-monster).
    #   * github_actions  — the conductor dispatches a GitHub Actions workflow and
    #     WATCHES it; the workflow does the Heroku push + hard /up smoke server-
    #     side, and the production Environment's required reviewer is the ship-
    #     confirm gate (the hub — DevOps v2 Phase 2).
    STRATEGY_HANDLERS = {
      "git_push_heroku" => :git_push_heroku,
      "repo_script" => :repo_script,
      "github_actions" => :github_actions
    }.freeze

    def strategy_handler(adapter)
      STRATEGY_HANDLERS.fetch(adapter.to_s) do
        known = STRATEGY_HANDLERS.keys.join(", ")
        raise ArgumentError, "unknown prod_deploy strategy: #{adapter.inspect} (known: #{known})"
      end
    end

    # --- github_actions deploy: WHICH run did our dispatch create? -------------
    #
    # bin/release's dispatch_and_watch fires `gh workflow run` and must then WATCH
    # the run it created — but `gh workflow run` prints no run id, and `gh run list
    # --limit 1` returns the newest run, which BEFORE ours registers is a PRIOR
    # concluded run of the same workflow (prod deploys repeat). Watching that stale
    # run would read a wrong verdict → a FALSE-GREEN production deploy.
    #
    # GitHub run ids increase monotonically, so the choice is: given the newest id
    # snapshotted BEFORE dispatch (`before_id`) and a newest id read during the
    # poll (`latest_id`), the dispatched run is the first `latest_id` STRICTLY
    # GREATER than `before_id`. This is the pure decision; the I/O (the two `gh run
    # list` reads, the retries, the sleeps) stays in the shell.
    #
    # FAILS CLOSED — nil in, nil out. `before_id` is nil when the shell could not
    # read the pre-dispatch snapshot (gh failed), and `latest_id` is nil on a
    # transient poll-read failure; either way NO run is selected, so the shell
    # aborts (or keeps polling) rather than latch the wrong run. `before_id` of 0
    # is the GENUINE empty case (the workflow had no prior runs) — the first run,
    # any id > 0, is then ours.
    def new_run_id(before_id, latest_id)
      return nil if before_id.nil? || latest_id.nil?

      latest_id > before_id ? latest_id : nil
    end

    # --- github_actions deploy: the fallback watcher's per-poll STATE verdict ---
    #
    # When `gh run watch` DIES on a transient blip (a real GitHub `connection reset
    # by peer` / HTTP 500 mid-watch, seen LIVE on run 29450907913), bin/release's
    # run_concluded_success? falls back to re-reading the run's own state. This is
    # the pure decision that turns one `gh run view --json status,conclusion` read
    # into a verdict; the polling/sleeping IO stays in the shell.
    #
    # THE BUG THIS FIXES: a prod-deploy run PAUSES at the `production` Environment's
    # required reviewer, reporting status `waiting` — for as long as the operator
    # takes to click (3h34m in the incident). The old fallback polled only for
    # `status == "completed"` on a 20×5s=100s budget, so a blip during that pause
    # read the still-`waiting` run as "never concluded" and failed the ship CLOSED
    # over a deploy that had simply not been approved yet. `completed` is the ONLY
    # terminal status GitHub reports; every other status (`waiting`, `queued`,
    # `in_progress`, and any GitHub might add) means the run is still LIVE.
    #
    #   * :success — completed + success → the deploy landed.
    #   * :failed  — completed + a non-success conclusion (failure/cancelled/
    #                timed_out/…) → a genuine terminal failure; fail closed PROMPTLY.
    #   * :pending — any non-`completed` status → the run is still live (paused for
    #                approval, queued, or running); KEEP WAITING. A mid-approval
    #                pause of ANY length is not a failed deploy. This is the fix.
    #
    # Note the asymmetry that keeps it fail-closed: an empty/unknown CONCLUSION on a
    # `completed` run is :failed (a completed run with no success is not a success),
    # while an empty/unknown STATUS is :pending (not completed = not concluded). The
    # shell's stuck-timeout — not this classifier — bounds an UNOBSERVABLE run (one
    # `gh run view` cannot read at all): reading a live status is affirmative proof
    # the run is alive, so an observable run holds exactly as `gh run watch` would.
    def run_watch_verdict(status, conclusion)
      return :pending unless status.to_s.strip == "completed"

      conclusion.to_s.strip == "success" ? :success : :failed
    end

    # Is the run PAUSED on a deployment-protection gate? The `waiting` status is
    # GitHub's signal for a protection rule holding a deployment (a required reviewer
    # or a wait timer). The `production` Environment's required-reviewer approval was
    # REMOVED on 2026-07-20 (task remove-prod-deploy-approval), so a normal prod run
    # no longer reaches `waiting`; this stays as defense-in-depth should a protection
    # rule ever be re-added — the status alone detects it, with no extra
    # `actions/runs/<id>/pending_deployments` read. Used only to tell the operator WHY
    # the watcher is holding (see run_concluded_success?); the run/skip decision is
    # run_watch_verdict's.
    def approval_pause?(status)
      status.to_s.strip == "waiting"
    end

    # --- post-ship accepted re-baseline: should we advance origin/accepted? -----
    #
    # After a ship fast-forwards a repo's `main` to the frozen SHA, that repo's
    # persistent `accepted` integration branch (feature branches are cut from and
    # PR into it) is left STALE behind `main` — nothing re-baselines it, so the
    # conductor has had to run `git push origin origin/main:refs/heads/accepted` by
    # hand after every ship. bin/release now does it automatically (advance_accepted),
    # and this is the pure guard for that advance. DevOps v2 Phase 3, Slice 1.
    #
    # TRUE only when BOTH hold:
    #   * the repo HAS an origin/accepted (`accepted_exists`) — the post-v2 accepted
    #     ladder. A repo without one (rolio/turf, pre-Phase-5) is a clean NO-OP:
    #     this returns false and the caller pushes nothing, AND
    #   * there is a frozen SHA to push. Blank is never advanced — the caller's main
    #     push would already have aborted on a blank SHA, but the guard owns the
    #     decision, so it stays honest on its own.
    #
    # The I/O — the `ls-remote` existence probe against the remote and the
    # fail-closed (no --force) ref push — stays in bin/release's advance_accepted;
    # only the yes/no lives here.
    def advance_accepted?(sha:, accepted_exists:)
      return false unless accepted_exists

      !sha.to_s.strip.empty?
    end

    # The app deploy groups with the hub pulled to the front, the rest left in
    # their incoming (producer-first) order. Stable: a non-hub group keeps its
    # relative position. Accepts symbol- OR string-keyed groups (repo_plan returns
    # symbols on the record side; the CLI sees string keys after JSON).
    def ordered_app_groups(app_groups)
      hub, rest = Array(app_groups).partition { |group| group_repo(group) == HUB }
      hub + rest
    end

    # The subset of `published_gem_names` whose line in `gemfile_text` still points
    # at a branch/source (so prod must be re-pinned to the published version before
    # it deploys). Composes GemfileRepin so the "what's a source ref" rule lives in
    # exactly one place. Already-pinned gems drop out → an idempotent re-pin pass.
    def gems_to_repin(published_gem_names, gemfile_text)
      Array(published_gem_names).select do |gem_name|
        Release::GemfileRepin.references_branch?(gemfile_text, gem_name)
      end
    end

    # --- prepare-side consumer bump: what does THIS Gemfile need? --------------
    #
    # prepare publishes gem members BEFORE the pre-QA gate and QA deploy (the
    # producer-first sequence, moved up from ship), then bumps each consumer's
    # COMMITTED Gemfile.lock on its release branch so CI, QA, and prod all build
    # the same lock. Per consumer × published gem, exactly one of:
    #   * :absent         — the Gemfile never declares the gem; touch nothing.
    #   * :rewrite_source — the line is a branch/source ref; re-pin it to the
    #                       published version (GemfileRepin.rewrite) + bump the lock.
    #   * :rewrite_pin    — a plain version pin the NEW version ESCAPES
    #                       (0.11.0 vs "~> 0.10"); rewrite the constraint
    #                       (GemfileRepin.rewrite_pin) + bump the lock.
    #   * :lock_only      — the pin already allows the new version (the standard
    #                       `~> x.y` patch/minor case); bump ONLY the lock.
    def consumer_bump_action(gemfile_text, gem_name, version)
      text = gemfile_text.to_s
      return :absent unless Release::GemfileRepin.gem_line_for(text, gem_name)
      return :rewrite_source if Release::GemfileRepin.references_branch?(text, gem_name)

      requirements = Release::GemfileRepin.version_requirements(text, gem_name)
      Release::GemfileRepin.constraint_allows?(requirements, version) ? :lock_only : :rewrite_pin
    end

    # The Gemfile text after the bump `consumer_bump_action` decided — the one
    # transform the shell applies per published gem before `bundle lock`.
    # :lock_only/:absent return the text unchanged (idempotent by construction).
    def bumped_gemfile(gemfile_text, gem_name, version)
      case consumer_bump_action(gemfile_text, gem_name, version)
      when :rewrite_source then Release::GemfileRepin.rewrite(gemfile_text, gem_name, version)
      when :rewrite_pin    then Release::GemfileRepin.rewrite_pin(gemfile_text, gem_name, version)
      else gemfile_text.to_s
      end
    end

    # --- prepare-side STRANDED-WORK guard: commits past the tag, version unbumped
    #
    # THE SILENT-SKIP HAZARD this closes: a gem repo's origin/release can carry
    # commits PAST the last published tag while its version_file still declares
    # the already-published number. publish_needed? then answers false ("already
    # live — skip"), consumers bundle the OLD gem, and the new commits silently
    # ride NOWHERE — the failure mode that stranded 9 engine commits with every
    # gate green. The guard turns that silence into a loud prepare abort.
    #
    # TRUE (stranded — BLOCK) only when BOTH hold:
    #   * commits exist past the last published tag (`ahead_commits` non-empty), AND
    #   * the version at origin/release did NOT ADVANCE past the tag's version.
    # NO prior tag (`tag_version` blank) is the first-ever publish — nothing to
    # strand behind.
    #
    # THE INVARIANT IS ORDERING, NOT EQUALITY. An earlier cut of this guard asked
    # `version == tag`, which is only the most obvious SPELLING of the violation
    # and let the worst vector through: a BACKWARD version (0.9.0 against tag
    # 0.10.0) passed the guard, publish_needed? answered false (0.9.0 is already
    # on RubyGems), phase 2 printed "already live — skip", and the consumer pin
    # was rewritten DOWNWARD — a production downgrade with every gate green and
    # the real commits stranded. `0.10` vs `0.10.0` slipped through the same hole
    # from the other side. So compare with Gem::Version (SEMANTIC, not textual)
    # and assert the positive property: did this version actually advance?
    #
    # FAIL-SAFE on unparseable input: a version we cannot order cannot PROVE it
    # advanced, so ArgumentError resolves to `true` (block) — never to publish.
    def stranded_gem_work?(ahead_commits:, version:, tag_version:)
      commits = Array(ahead_commits).map(&:to_s).map(&:strip).reject(&:empty?)
      return false if commits.empty?

      tag = tag_version.to_s.strip
      return false if tag.empty?

      begin
        Gem::Version.new(version.to_s.strip) <= Gem::Version.new(tag)
      rescue ArgumentError
        true
      end
    end

    # The loud, ACTIONABLE abort for stranded_gem_work?: name the repo, the
    # stranded commits, and the exact fix (bump the version_file through its own
    # PR, then re-run prepare) — never a bare "refusing".
    #
    # `tag_version` is REQUIRED and distinct from `version`: the guard now fires
    # on ordering, so the two genuinely differ in the backward case (version
    # 0.9.0, tag 0.10.0). Printing `version` as the tag — correct only while the
    # guard fired solely on equality — would have told the operator the tag was
    # v0.9.0 and buried the downgrade the message exists to expose.
    def stranded_gem_message(repo, ahead_commits:, version:, version_file:, tag_version:)
      commits = Array(ahead_commits).map(&:to_s).map(&:strip).reject(&:empty?)
      sample  = commits.first(10).map { |c| "      #{c}" }.join("\n")
      more    = commits.size > 10 ? "\n      (+#{commits.size - 10} more)" : ""
      tag     = tag_version.to_s.strip
      behind  = begin
        Gem::Version.new(version.to_s.strip) < Gem::Version.new(tag)
      rescue ArgumentError
        false
      end
      verdict = if behind
                  "#{version_file} declares #{version}, which is BEHIND the published tag — publishing " \
                    "would DOWNGRADE consumers to an older gem"
                else
                  "#{version_file} still declares #{version} — publishing would silently SKIP " \
                    "(\"already live\") and QA/prod consumers would bundle the OLD gem"
                end
      "#{repo} origin/release carries #{commits.size} commit(s) past the last published tag " \
        "v#{tag} while #{verdict}, STRANDING these commits:\n#{sample}#{more}\n" \
        "  Bump the version in #{repo}/#{version_file} PAST #{tag} (the bump rides the gem's own PR " \
        "through the cycle), land it on origin/release, then re-run `bin/release prepare`."
    end

    # --- resuming a PARTIAL ship: the re-pin must be idempotent BY IDENTITY -----
    #
    # THE WEDGE this closes (reproduced on real git, 2026-07-12 — jasper, PR #517):
    # auto-re-pin mints a NEW commit on top of the frozen SHA and advances the ship
    # SHA to it — but `qa_shas` (the release record) still holds the ORIGINAL frozen
    # SHA, and nothing ever rewrites it. So a ship that publishes the gems, pushes
    # the re-pin, and THEN dies (a failed deploy, a dropped connection) leaves:
    #   origin/release = repin₁   ·   qa_shas = frozen   ·   gems already published
    # The retry re-derives its ship SHA from `qa_shas`, resets the workspace to
    # `frozen`, finds the frozen tree's Gemfile still branch-ref'd, decides a re-pin
    # is needed — and then sees origin/release ≠ frozen and treats ITS OWN re-pin as
    # un-QA'd drift: "re-run `bin/release prepare` to re-QA". After the gems have
    # published. The ship cannot be resumed. And underneath that guard sits a second
    # failure: the retry would mint repin₂ — a DIFFERENT commit object with the same
    # tree — whose push is non-fast-forward against repin₁, so it fails there too
    # (verified by neutralizing the guard). The ship's own banner promises "re-pins
    # are idempotent". They were not.
    #
    # THE FIX: make the re-pin idempotent BY IDENTITY. Before treating a moved
    # origin/release as drift, ask whether it IS the re-pin this run would have
    # written — and if so, REUSE it (ship that commit) instead of minting a rival.
    #
    # It qualifies ONLY on all three, and FAILS CLOSED on anything else — this
    # decides what reaches PRODUCTION, and "close enough" is not a standard:
    #   * ANCESTRY — the frozen SHA is an ancestor of the head, so the head is
    #     frozen PLUS something, never a divergent line of development.
    #   * SHAPE — that something touches ONLY Gemfile/Gemfile.lock. This is the
    #     original guard's real intent, preserved exactly: no code may ride to prod
    #     un-QA'd under cover of a re-pin.
    #   * IDENTITY — the head's Gemfile is BYTE-IDENTICAL to what this run would
    #     write (the frozen Gemfile with the published pins applied). Not merely
    #     "no branch refs remain" — that weaker test would wave through a Gemfile
    #     someone pinned to the WRONG version, and prod would build it.
    # A commit that satisfies all three is, by construction, the commit this run was
    # about to create. Shipping it is not a guess; it is the same act, completed.
    REPIN_FILES = %w[Gemfile Gemfile.lock].freeze

    def resumable_repin?(ancestor:, changed_files:, head_gemfile:, expected_gemfile:)
      return false unless ancestor

      files = Array(changed_files).map(&:to_s).map(&:strip).reject(&:empty?)
      return false if files.empty?          # nothing changed — not a re-pin at all
      return false if (files - REPIN_FILES).any? # code rode along — NOT a mechanical re-pin

      expected = expected_gemfile.to_s
      return false if expected.empty?

      head_gemfile.to_s == expected
    end

    # Should we publish `version`? No when it is already LIVE on RubyGems (an
    # idempotent skip — the gem made it in a prior run). `remote_versions` is the
    # RubyGems versions listing from /api/v1/versions/<gem>.json: an array of
    # { "number" => ... } entries, all LIVE — RubyGems excludes yanked versions
    # from the listing entirely (there is no `yanked` field). It also accepts a
    # plain array of version strings (the `gem list` shape). A yanked number is
    # simply absent → publish_needed? is true → ship attempts the push → RubyGems
    # rejects re-pushing it → publish_gem aborts. That is the yank safety, and it
    # fails closed at `gem push`, so there is no listing-based yanked? check.
    def publish_needed?(version, remote_versions)
      !live_numbers(remote_versions).include?(version.to_s)
    end

    # The QA-frozen SHA to ship for `repo` — the value `bin/release prepare`
    # recorded under release.metadata["qa_shas"] (apps AND gems both freeze their
    # origin/release HEAD there). Returns the frozen SHA string when present, or
    # nil to SIGNAL the caller to fall back to resolving origin/release HEAD live
    # — for a repo absent from qa_shas, or one prepared before SHA recording. Pure:
    # the live git fallback stays in bin/release's frozen_sha_for, which delegates
    # this decision here so the shell keeps no branching of its own. A blank
    # recorded value reads as absent (fall back). Accepts string- or symbol-keyed
    # qa_shas (the CLI passes JSON string keys; the record side may use symbols).
    def frozen_sha(qa_shas, repo)
      shas = qa_shas || {}
      sha = (shas[repo] || shas[repo.to_s] || shas[repo.to_sym]).to_s
      sha.empty? ? nil : sha
    end

    # --- G4 self-gating: skip a ship test gate G3 already certified ------------
    #
    # The 90/10 policy runs the full suite ONCE per release batch: the hub
    # registers its FULL suite as `qa_test_cmd`, so the G3 pre-QA gate certifies
    # the batch on origin/release BEFORE anything deploys. Re-running the ship
    # test gate then proves nothing new — so G4 may skip it. But it may ONLY skip
    # on PROOF that G3 actually ran and passed.
    #
    # SAFETY BUG this closes (found 2026-07-12): the old predicate inferred that
    # proof from the REGISTRY plus `qa_shas` — `test_cmd == qa_test_cmd &&
    # frozen_sha == qa_sha`. Neither term proves a suite ever RAN:
    #   * `qa_shas` is stamped by the QA DEPLOY LOOP (bin/release.rb), not by the
    #     gate. It records what was DEPLOYED, never what was CERTIFIED.
    #   * the registry is read fresh at ship, so it can differ from what prepare
    #     read minutes earlier.
    # Together they let G3 skip and G4 STILL self-skip — silently disarming the
    # production gate. The documented gate-skip recipe walked exactly into this:
    # comment out `qa_test_cmd` so prepare's gate skips, then RESTORE the file
    # before ship (ship's preflight REFUSED a dirty primary back then) — and now
    # the registry reads equal again, the deployed SHA matches, and G4 skips a
    # suite NOTHING ever ran. A skipped G3 must never certify a SHA.
    #
    # THE FIX: skip only against the gate's OWN recorded verdict —
    # release.metadata["qa_gates"][repo] = {"sha", "cmd", "ok"}, written by
    # pre_qa_gate ONLY after the suite comes back green (Conductor.record_qa_gate).
    # Skip iff that record exists, is green, and matches BOTH the command the ship
    # gate would run AND the frozen ship SHA. Anything else — no record, a red
    # record, a different command, a drifted/straggler SHA — FAILS OPEN and runs
    # the gate. The caller (bin/release test_gate) records the skip as a visible
    # gate SOP, never a silent omission.
    #
    # AND: a G3 whose AUDITOR went red (`record["ci"]["state"] == "red"` — GitHub
    # CI called that same SHA broken while the local gate called it green) also
    # FAILS OPEN. This is what makes G4 a real backstop for the cross-check's
    # dangerous direction instead of a claimed one: on a green G3 the frozen ship
    # SHA is the certified SHA, so WITHOUT this clause the skip fires and the G3
    # alarm is the ONLY thing between a CI-red commit and production. A gate
    # system that claims a backstop it does not have makes its own alarm
    # dismissible.
    #
    # FAIL-OPEN ONLY, NEVER FAIL-CLOSED. The auditor may cause MORE checking; it
    # may never block a ship on its own. Only the literal state "red" arms this —
    # "none"/"pending"/"unverified" (GitHub had nothing to say: today ci.yml
    # doesn't even build `release`) and an absent "ci" key are SILENCE, and
    # silence changes nothing. The cost of a false red is one redundant suite run.
    def ship_gate_skip?(test_cmd:, frozen_sha:, qa_gate:)
      cmd = test_cmd.to_s.strip
      sha = frozen_sha.to_s.strip
      return false if cmd.empty? || sha.empty?

      record = qa_gate.is_a?(Hash) ? qa_gate : {}
      return false unless record["ok"] == true || record[:ok] == true
      return false if auditor_red?(record)

      certified_cmd = (record["cmd"] || record[:cmd]).to_s.strip
      certified_sha = (record["sha"] || record[:sha]).to_s.strip
      certified_cmd == cmd && certified_sha == sha
    end

    # Did GitHub CI call the SHA G3 certified BROKEN? Only a literal "red" counts
    # (see ship_gate_skip?): every other state — and no auditor at all — is no
    # data, and no data must never arm or block the ship gate.
    def auditor_red?(qa_gate)
      record = qa_gate.is_a?(Hash) ? qa_gate : {}
      ci = record["ci"] || record[:ci]
      return false unless ci.is_a?(Hash)

      (ci["state"] || ci[:state]).to_s == "red"
    end

    # The G3 gate record for a repo out of release.metadata["qa_gates"] (the twin
    # of frozen_sha for qa_shas). nil when the gate never recorded a verdict for
    # this repo — which ship_gate_skip? reads as "not certified" and runs the gate.
    def qa_gate(qa_gates, repo)
      gates = qa_gates.is_a?(Hash) ? qa_gates : {}
      record = gates[repo] || gates[repo.to_s] || gates[repo.to_sym]
      record.is_a?(Hash) ? record : nil
    end

    # --- resuming a KILLED ship: is the frozen SHA ALREADY live on prod? --------
    #
    # THE STRAND THIS ANSWERS (hit twice — Slice-4, rel-20260716-2a2075). For the
    # github_actions hub, `bin/release ship` DISPATCHES prod-deploy.yml and then
    # WATCHES the run as a long-lived process. GitHub Actions owns the Heroku push +
    # /up smoke INDEPENDENTLY of that watcher, so when the harness/OS KILLS the
    # watch process (an IOError, stream-closed) the DEPLOY still lands — push_frozen_
    # main already advanced main, accepted auto-advanced, prod is live — but the
    # record+seal+install steps (Conductor.ship!, the smoke seal, install-agent-docs)
    # NEVER run, and the board strands at `assembled`. Both `bin/release finalize`
    # (record the skipped steps) and a `ship` RE-RUN (skip the redundant re-dispatch)
    # turn on this one question, so it lives here, pure and unit-tested.
    #
    # TRUE only on AFFIRMATIVE, strategy-appropriate proof the frozen SHA deployed —
    # this decides what gets marked `shipped`, so it FAILS CLOSED on anything less.
    #
    # CRITICAL: `main_at_sha` (origin/main == frozen) is NOT proof of deployment on
    # its own, because the caller runs push_frozen_main — which advances origin/main
    # to the frozen SHA — BEFORE the actual prod deploy. So on a normal FIRST ship
    # main_at_sha is already true while prod still serves the OLD build (and its /up
    # still returns 200). The distinguishing signal must come from the deploy itself:
    #   * github_actions — main advanced to the SHA (main_at_sha), prod /up is 200
    #     (up_ok), AND a prod-deploy run FOR THE SHA concluded success (run_success,
    #     from prod_run_succeeded?, which matches headSha == the frozen SHA). That
    #     SHA-matched run is exactly the verdict a killed watcher lost, and it does
    #     NOT exist yet on a first ship (the dispatch happens after this check) — so
    #     it cleanly tells a re-run's landed deploy from a first ship's advanced main.
    #   * git_push_heroku / repo_script — the deploy runs INLINE (a Heroku-remote
    #     push / the repo's own script), so there is no dispatched run to consult AND
    #     main_at_sha proves nothing. Each needs its OWN deployed-marker AT the SHA
    #     (deployed_at_sha — the Heroku release SHA / turf's mainnet-release marker).
    #     Absent it this stays false and the caller re-runs the deploy: an inline
    #     re-run is cheap and idempotent (a same-SHA Heroku push is "up-to-date"; a
    #     repo_script self-gates + self-rolls-back), where a false "already shipped"
    #     is not — so failing closed here costs nothing and buys safety.
    # Every unknown strategy is false (never mark an unrecognized deploy shipped).
    def deploy_already_succeeded?(strategy:, up_ok:, main_at_sha: false,
                                  run_success: nil, deployed_at_sha: nil)
      return false unless up_ok == true

      case strategy.to_s
      when "github_actions" then main_at_sha == true && run_success == true
      when "git_push_heroku", "repo_script" then deployed_at_sha == true
      else false
      end
    end

    # Did a prod-deploy run FOR `sha` conclude success? `runs` is the `gh run list`
    # for the deploy workflow — an array of { "headSha", "status", "conclusion" }.
    # A `workflow_dispatch` run's headSha is the ref HEAD at dispatch, and
    # push_frozen_main advances main to the frozen SHA BEFORE the dispatch, so the
    # run that deployed the frozen SHA carries headSha == sha — that is how the
    # right run is identified WITHOUT reading workflow_dispatch inputs (which gh
    # does not surface in `run list`). TRUE iff some matching run is completed +
    # success (run_watch_verdict owns that per-run read). FAILS CLOSED: a blank
    # sha, an empty/garbled list, or no SHA match → false (re-verify beats a false
    # green).
    def prod_run_succeeded?(runs, sha)
      target = sha.to_s.strip
      return false if target.empty?

      Array(runs).any? do |run|
        record = run.is_a?(Hash) ? run : {}
        head = (record["headSha"] || record[:headSha]).to_s.strip
        next false unless head == target

        run_watch_verdict(record["status"] || record[:status],
                          record["conclusion"] || record[:conclusion]) == :success
      end
    end

    # --- finalize: WHICH record+seal+install steps did the killed ship skip? -----
    #
    # Given the release's post-deploy state, the ordered steps `bin/release finalize`
    # still needs to run — so a finalize does ONLY the missing work, and a re-run on
    # an already-finalized release is an EMPTY list (a clean no-op: no double Discord
    # notes, no double records). The steps themselves are individually idempotent
    # (Conductor.ship! skips already-shipped members via idempotency keys; the seal
    # + install-docs are idempotent), but post_release_notes DELIVERS to Discord on
    # EVERY call — so this is the guard that keeps a second finalize from re-posting.
    #   * :seal  — the prod smoke seal was never recorded (release has no seal).
    #   * :ship  — Conductor.ship! has work left: the release is not `shipped`, OR
    #     it is shipped but member tasks are still unflipped (the kill landed
    #     MID-member-cadence). Release#ship! resumes the stragglers in that case and
    #     is a safe re-run; it ONLY raises "already terminal" once state==shipped AND
    #     every member is shipped — which is exactly when :ship drops out here.
    #   * :notes — release notes were never delivered (release_notes not completed).
    # :seal precedes :ship precedes :notes so the seal is recorded before the notes
    # read it, exactly as the live ship orders steps 5c → 6. The primary-restore +
    # install-agent-docs steps are idempotent file ops the CLI rides along whenever
    # ANY step is pending; they are not gated here.
    FINALIZE_ORDER = %i[seal ship notes].freeze

    def finalize_pending?(state:, sealed:, notes_completed:, members_all_shipped: true)
      done = {
        seal: sealed == true,
        ship: state.to_s == "shipped" && members_all_shipped == true,
        notes: notes_completed == true
      }
      FINALIZE_ORDER.reject { |step| done[step] }
    end

    # --- ship preflight -------------------------------------------------------
    #
    # HISTORY — why this is no longer a GATE for apps (2026-07-12). ship used to
    # fast-forward each app repo's `main` in the SHARED PRIMARY and run the
    # satellites' bin/deploy there, so it REFUSED a primary that was dirty or off
    # `main`. That refusal aborted a real production ship AFTER the gems had
    # published, because a concurrent feature session had staged work in the
    # primary — work nobody may discard. The deploy now runs from its own
    # workspace (Release::GateWorkspace, role "ship") and advances `main` with a
    # ref push that reads no working tree at all, so an app primary's state is
    # simply NOT INPUT to the ship any more. What was an abort is now an ADVISORY
    # (advisory_message): the ship says it isn't reading the tree, prints the
    # rescue, and deploys.
    #
    # This detector is the PURE half of that advisory: the I/O (git rev-parse /
    # status) lives in bin/release's ship_preflight, which hands the gathered
    # states here.
    #
    # `states` is an array of string-keyed hashes, one per repo:
    #   { "repo" => ..., "branch" => <current branch>,
    #     "dirty" => <bool>, "dirty_files" => [paths], "tracked_dirty" => [paths] }
    # `dirty` is optional — if absent it's inferred from a non-empty dirty_files.
    # Returns the OFFENDERS (repos not on `main` OR with a dirty tree), each as:
    #   { "repo" =>, "branch" =>, "on_main" => <bool>, "dirty" => <bool>,
    #     "dirty_files" => [paths] }
    # An empty result means every checkout is on a clean `main`.
    def preflight_offenders(states)
      Array(states).filter_map do |s|
        branch    = (s["branch"] || s[:branch]).to_s
        all_files = Array(s["dirty_files"] || s[:dirty_files]).map(&:to_s).reject(&:empty?)
        # Drop KNOWN-GENERATED artifacts (a `bin/release retro` doc, the
        # agent-worktree ledger) — they routinely sit uncommitted in the deploy
        # checkout and counting them as dirt blocked EVERY ship's fast-forward.
        # Narrow allowlist (see GENERATED_ARTIFACT_GLOBS), NOT a blanket docs/
        # ignore — any other dirty file still gates the ship.
        files = all_files.reject { |f| generated_artifact?(f) }
        dirty = if all_files.any?
                  # A concrete file list is authoritative: dirty IFF a non-
                  # generated file remains after the allowlist.
                  files.any?
                elsif s.key?("dirty") || s.key?(:dirty)
                  # No file list given — honor an explicit dirty flag (legacy shape).
                  !!(s["dirty"] || s[:dirty])
                else
                  false
                end
        on_main = branch == "main"
        next if on_main && !dirty

        { "repo" => (s["repo"] || s[:repo]).to_s, "branch" => branch,
          "on_main" => on_main, "dirty" => dirty, "dirty_files" => files }
      end
    end

    # Generated artifacts that routinely sit UNCOMMITTED in a deploy checkout but
    # are NOT real code dirt, so the ship preflight must not count them as dirty
    # (they blocked EVERY ship's fast-forward otherwise):
    #   * docs/agents/audits/retro-rel-*.md     — written by `bin/release retro`
    #   * docs/agents/maintenance/delete-later.md — the `bin/agent-worktree` ledger
    # A NARROW allowlist of globs, NOT a blanket docs/ ignore: any other dirty
    # file — including other docs — still gates a gem build.
    GENERATED_ARTIFACT_GLOBS = [
      "docs/agents/audits/retro-rel-*.md",
      "docs/agents/maintenance/delete-later.md"
    ].freeze

    # The worktree parent — the gate + ship workspaces, and the agent worktrees,
    # all live under it. Every app repo gitignores it, but that is a CONVENTION
    # (a newly-onboarded repo can miss the .gitignore line), and if it is ever
    # missed the ship's own `.worktrees/_ship` would show up in `git status` as
    # the operator's "stranded work" — the advisory would name it, and the rescue
    # command would COMMIT THE WORKSPACE INTO GIT. It is tooling output by
    # definition, never anyone's work, so it can never count as dirt.
    WORKSPACE_DIR = ".worktrees".freeze

    # Whether a repo-root-relative `path` (as `git status --porcelain` emits it)
    # is a known generated artifact. Pure string match (File.fnmatch touches no
    # filesystem); FNM_PATHNAME keeps `*` from spanning `/`, so the glob can't
    # over-ignore a nested path. A blank path is never an artifact. `git status`
    # reports an untracked DIRECTORY with a trailing slash (`.worktrees/`), so the
    # path is normalized before matching.
    def generated_artifact?(path)
      p = path.to_s.strip.chomp("/")
      return false if p.empty?
      return true if p == WORKSPACE_DIR || p.start_with?("#{WORKSPACE_DIR}/")

      GENERATED_ARTIFACT_GLOBS.any? { |glob| File.fnmatch?(glob, p, File::FNM_PATHNAME) }
    end

    # The app-primary ADVISORY (never an abort). The ship does not read these
    # trees — it deploys from its own workspace at the frozen SHA — so a dirty or
    # off-main primary is now just a note, plus the rescue for the operator who
    # WANTS it clean. Says what the ship is doing so nobody reads the note as a
    # failure. nil when every primary is already clean (print nothing).
    def advisory_message(offenders, at: Time.now, root: "<projects>")
      list = Array(offenders)
      return nil if list.empty?

      lines = list.flat_map do |o|
        ["  - #{o['repo']}: #{offender_reasons(o).join('; ')}"] +
          rescue_commands(o, at: at, root: root).map { |c| "      #{c}" }
      end
      "  ⚠ app primary checkout(s) NOT on a clean `main` — the ship does NOT read them " \
        "(it deploys from its own workspace at the frozen SHA), so this is a NOTE, not a blocker:\n" \
        "#{lines.join("\n")}\n" \
        "    Nothing here is discarded, and nothing is stashed. The commands above park the work on a " \
        "labeled branch if you want the primary clean; a live session's work is safe either way."
    end

    # The ONE primary dependency the ship still has: a GEM artifact is BUILT from
    # the gem repo's primary checkout (`git checkout <frozen>` there, then `gem
    # build`), and `gem build` packages the files it finds ON DISK. So a MODIFIED
    # TRACKED file in a gem primary would be PUBLISHED — a wrong-code release,
    # irreversible (RubyGems forbids re-pushing a version). That is worth an abort;
    # nothing else about a primary is.
    #
    # Narrow ON PURPOSE — tracked modifications only:
    #   * untracked files are NOT packaged (the gemspec's file list is `git
    #     ls-files`), so they are not a correctness hazard and must not gate a ship;
    #   * the branch does not matter (the build detaches to the frozen SHA anyway).
    # An empty result means no gem would package local dirt — safe to build.
    def gem_build_offenders(states)
      Array(states).filter_map do |s|
        files = Array(s["tracked_dirty"] || s[:tracked_dirty]).map(&:to_s).reject(&:empty?)
        files = files.reject { |f| generated_artifact?(f) }
        next if files.empty?

        { "repo" => (s["repo"] || s[:repo]).to_s, "branch" => (s["branch"] || s[:branch]).to_s,
          "on_main" => true, "dirty" => true, "dirty_files" => files }
      end
    end

    # The loud, ACTIONABLE abort for gem_build_offenders. It leads with the stakes
    # (this would publish your uncommitted code) and hands over the exact rescue —
    # never "stash or discard", which is how a live session's work gets destroyed.
    def gem_build_message(offenders, at: Time.now, root: "<projects>")
      lines = Array(offenders).flat_map do |o|
        files  = Array(o["dirty_files"])
        sample = files.first(5).join(", ")
        more   = files.size > 5 ? " (+#{files.size - 5} more)" : ""
        ["  - #{o['repo']}: modified tracked file(s)#{sample.empty? ? '' : ": #{sample}#{more}"}"] +
          rescue_commands(o, at: at, root: root).map { |c| "      #{c}" }
      end
      "ship aborted BEFORE publishing anything — a gem repo's primary has uncommitted changes to TRACKED " \
        "files, and `gem build` packages what is on disk, so those edits would be PUBLISHED to RubyGems " \
        "(a version can never be re-pushed):\n" \
        "#{lines.join("\n")}\n" \
        "  The commands above COMMIT that work to a labeled branch — nothing is stashed and nothing is " \
        "discarded (it may be a live session's). Then re-run `bin/release ship`."
    end

    # The rescue: park a primary's stranded work on a LABELED BRANCH and hand the
    # checkout back clean. Commit, never stash and never discard — the work may
    # belong to a live agent session, and a stash is easy to lose (and its message
    # is only a push-time label).
    #
    # THE ONE RESCUE. Every surface that shows an operator a dirty primary prints
    # THIS (the ship preflight's advisory, the gem-build abort, and
    # RestorePrimary's post-ship refusal) — because a tool that says "never stash"
    # in one breath and "stash/discard the changes" in the next is worse than one
    # that says nothing, and an operator does what the tool tells them.
    #
    # Pure: `at:` and `root:` are injectable — `at:` so the branch name is
    # deterministic under test, `root:` so the caller can hand over PASTE-READY
    # paths instead of a `<projects>` placeholder the operator must substitute by
    # hand at the worst possible moment.
    def rescue_commands(offender, at: Time.now, root: "<projects>")
      repo   = (offender["repo"] || offender[:repo]).to_s
      path   = "#{root}/#{repo}"
      branch = "rescue/#{repo}-#{at.strftime('%Y%m%d-%H%M%S')}"
      dirty  = offender["dirty"] || offender[:dirty]
      return ["git -C #{path} checkout main   # (clean tree — just leave the review branch)"] unless dirty

      [
        "git -C #{path} switch -c #{branch}   # carries the work over, discards nothing",
        "git -C #{path} add -A && git -C #{path} commit -m 'rescue: stranded primary work'",
        "git -C #{path} switch main   # primary is clean again; the work lives on #{branch}"
      ]
    end

    # --- internals -----------------------------------------------------------

    def offender_reasons(offender)
      reasons = []
      reasons << "on '#{offender['branch']}', not 'main'" unless offender["on_main"]
      if offender["dirty"]
        files  = Array(offender["dirty_files"])
        sample = files.first(5).join(", ")
        more   = files.size > 5 ? " (+#{files.size - 5} more)" : ""
        reasons << "dirty tree#{sample.empty? ? '' : ": #{sample}#{more}"}"
      end
      reasons
    end

    def group_repo(group)
      (group[:repo] || group["repo"]).to_s
    end

    # The version numbers in a RubyGems listing. The listing is already live-only
    # (yanked versions don't appear), so this is a straight map to number strings.
    def live_numbers(remote_versions)
      Array(remote_versions).map { |entry| version_number(entry) }
    end

    # The version string out of either a {"number" => "x"} hash (the versions API
    # shape) or a bare "x" (the `gem list` shape).
    def version_number(entry)
      (entry.is_a?(Hash) ? (entry["number"] || entry[:number]) : entry).to_s
    end
  end
end
