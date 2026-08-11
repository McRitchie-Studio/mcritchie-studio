class Release
  # Pure decision logic for the CLEAN-LADDER GUARD that Avi's `deploy-with-task`
  # act runs FIRST. Like Release::Cli / MergePlan / ShipSequence
  # this is deliberately IO-free and Rails-free: it takes the already-gathered
  # board + git state in and returns the clean/dirty verdict plus the
  # operator-facing message out, so the "is it safe to expedite one task" decision
  # lives in ONE unit-tested place. (bin/release `require_relative`s this file
  # directly, so it must load standalone with no Rails dependency.)
  #
  # WHY IT EXISTS: `deploy-with-task` expedites a SINGLE task to prod, and it
  # carries PRODUCTION AUTHORITY for that one task. Its entire safety argument is
  # this guard, so the guard must cover EVERY rung the expedite walks. The ladder
  # is `accepted → release → main` and the expedite walks all of it: review merges
  # the task's PR onto `accepted`, the sweep promotes ALL of `accepted` onto
  # `release`, and the ship fast-forwards `release → main`. So TWO separate pools
  # of other work can ride out alongside the expedited task:
  #   * anything already on `release` ahead of `main` — `assembled` (QA-green) or
  #     still `reviewed` with merged:"release" (swept, QA in flight) — which the
  #     ff drags to `main`; and
  #   * anything already on `accepted` ahead of `release` — `reviewed` with
  #     merged:"accepted" (reviewed, not yet swept) — which the SWEEP drags onto
  #     `release`, and from there the ff drags to `main`.
  # Checking only the `release` rung is how a reviewed-but-unswept task could ship
  # to production with the guard fully green: the operator was told the release
  # was clean, and it was — the rung BELOW it was not. Expediting is safe only
  # when `accepted == release == main`. On a DIRTY ladder the guard REFUSES and
  # OFFERS the `Alex Heartbeat` `full-cycle` launcher (ship the WHOLE release)
  # instead of silently shipping the pending work.
  #
  # It reads FOUR signals — a BOARD signal and a GIT signal for each rung — and is
  # FAIL-CLOSED: any one of them showing pending work makes the ladder dirty.
  #   release rung
  #     * board — tasks riding `release` pending ship: `assembled` (QA-green) plus
  #       `reviewed` with merged:"release" (swept by Avi, QA in flight).
  #     * git   — commits `origin/release` is ahead of `origin/main`, per repo.
  #   accepted rung
  #     * board — `reviewed` tasks stamped merged:"accepted" (code landed on
  #       `accepted`, not yet swept onto `release`).
  #     * git   — commits `origin/accepted` is ahead of `origin/release`, per repo.
  #
  # PAIRING THE SIGNALS IS THE POINT, not redundancy. Each catches the other's
  # blind spot: a task parked on a rung with no commits still trips the board
  # signal, and a commit pushed straight to `accepted`/`release` with no task
  # behind it still trips the git signal. That matters most on the accepted rung,
  # because the board signal there depends on the `merged` stamp having been
  # written — and a stamp that was never written would reopen this same hole one
  # layer down. So GIT IS THE PRIMARY SIGNAL on that rung and the stamp
  # corroborates it. When the two DISAGREE the verdict says so
  # (`signal_conflict`): a disagreement is itself information — a missing or
  # stale `merged` stamp, or a commit that landed on `accepted` with no task. The
  # guard already refuses either way (fail-closed); naming the disagreement tells
  # the operator WHICH record to go fix instead of trusting whichever one happens
  # to look clean.
  #
  # A read that FAILED is not a read that came back clean. A rung whose count
  # could not be measured (`unreadable_repos`) is dirty too — silently skipping an
  # unmeasurable repo is the same shape of bug as never measuring the rung at all.
  module CleanCheck
    module_function

    # pending_tasks:    [{ "slug" =>, "title" => }, …] — tasks riding `release`
    #   pending ship (the release rung's board signal: `assembled`, plus
    #   `reviewed` with merged:"release"). String OR symbol keys tolerated.
    # repo_states:      [{ "repo" =>, "ahead" => Integer }, …] — commits
    #   origin/release is ahead of origin/main per release repo (the release
    #   rung's git signal); ahead == 0 means that repo's release == main.
    # accepted_tasks:   [{ "slug" =>, "title" => }, …] — `reviewed` tasks stamped
    #   merged:"accepted" (the accepted rung's board signal): reviewed, code on
    #   `accepted`, waiting for the sweep.
    # accepted_states:  [{ "repo" =>, "ahead" => Integer }, …] — commits
    #   origin/accepted is ahead of origin/release per release repo (the accepted
    #   rung's git signal). Pass EVERY repo actually measured, ahead == 0
    #   included: an empty array means the git read did not run (e.g. --dry-run),
    #   and that is what suppresses the conflict check rather than faking agreement.
    # unreadable_repos: [{ "repo" =>, "rung" => }, …] — repos whose rung count
    #   could not be read at all (missing branch, failed rev-list). Always dirty.
    # expedited:        the slug `deploy-with-task` is expediting, when the caller
    #   passed `--task`. It is EXCLUDED from the accepted rung's board signal —
    #   the SOP allows re-running the act on a task review already merged onto
    #   `accepted`, and refusing on the operator's own task would make the lane
    #   unusable. See `attributed_ahead` below for the git half of that.
    # Returns a JSON-friendly, string-keyed verdict:
    #   "clean"                => Boolean — accepted == release == main, modulo the
    #                             expedited task (safe to expedite one task)
    #   "pending_tasks"        => normalized tasks riding `release` (empty when clean)
    #   "ahead_repos"          => repos with release ahead of main (empty when clean)
    #   "accepted_tasks"       => tasks parked on `accepted`, EXCLUDING the
    #                             expedited one (empty when clean)
    #   "accepted_ahead_repos" => repos with accepted ahead of release that are NOT
    #                             attributed to the expedited task (empty when clean)
    #   "attributed_ahead_repos" => repos whose accepted-ahead commits were
    #                             attributed to the expedited task (informational;
    #                             the message always says so out loud)
    #   "unreadable_repos"     => rung reads that failed (empty when clean)
    #   "signal_conflict"      => nil, or a sentence naming a board-vs-git
    #                             disagreement on the accepted rung
    #   "message"              => the operator-facing verdict line(s): a short OK
    #                             when clean, or the REFUSAL + `Alex Heartbeat`
    #                             full-cycle OFFER (listing the pending work and any
    #                             signal conflict) when dirty.
    def evaluate(pending_tasks: [], repo_states: [], accepted_tasks: [],
                 accepted_states: [], unreadable_repos: [], expedited: nil)
      pending = normalize_tasks(pending_tasks)
      ahead   = ahead_repos(repo_states)

      slug = expedited.to_s.strip
      accepted_all = normalize_tasks(accepted_tasks)
      # The expedited task is the ONE thing allowed on the rung, so it never
      # counts against its own guard.
      expedited_parked = !slug.empty? && accepted_all.any? { |t| t["slug"].to_s == slug }
      accepted = accepted_all.reject { |t| !slug.empty? && t["slug"].to_s == slug }

      measured_ahead = ahead_repos(accepted_states)
      # Attribution is the ONLY way a positive accepted-ahead count passes, and it
      # takes BOTH: the operator named the task (so the commits have a claimed
      # owner) AND the board agrees that task is the sole occupant of the rung. A
      # bare `--clean-only` with no `--task` never attributes anything, so the
      # default stays strictly git-primary.
      attributed = expedited_parked && accepted.empty?
      accepted_ahead = attributed ? [] : measured_ahead
      attributed_ahead = attributed ? measured_ahead : []

      unreadable = normalize_unreadable(unreadable_repos)
      # An empty accepted_states means the git read did not run, and an unmeasured
      # signal can neither corroborate nor contradict the stamp — so the conflict
      # check stays silent rather than reporting a disagreement with a signal that
      # was never taken.
      git_measured = Array(accepted_states).any?
      conflict = accepted_signal_conflict(accepted, measured_ahead, git_measured, attributed)

      clean = pending.empty? && ahead.empty? && accepted.empty? &&
              accepted_ahead.empty? && unreadable.empty?
      {
        "clean" => clean,
        "pending_tasks" => pending,
        "ahead_repos" => ahead,
        "accepted_tasks" => accepted,
        "accepted_ahead_repos" => accepted_ahead,
        "attributed_ahead_repos" => attributed_ahead,
        "unreadable_repos" => unreadable,
        "signal_conflict" => conflict,
        "message" => clean ? clean_message(slug, attributed_ahead) : dirty_message(
          pending, ahead, accepted, accepted_ahead, unreadable, conflict
        )
      }
    end

    # The OK line. When a positive accepted-ahead count was attributed to the
    # expedited task, say so on its own line — the operator should never learn
    # from a silent pass that the guard tolerated commits.
    def clean_message(slug = nil, attributed_ahead = [])
      lines = ["✓ the ladder is clean (accepted == release == main) — " \
               "safe to expedite one task with the `deploy-with-task` act."]
      if attributed_ahead.any?
        lines << "  `accepted` carries #{repo_summary(attributed_ahead)}, attributed to the expedited " \
                 "task `#{slug}` (stamped merged:\"accepted\"); the board shows no other task on that rung."
      end
      lines.join("\n")
    end

    # The refusal + the offer. Never silently drags the pending work to prod: it
    # names WHAT is pending, on WHICH rung, and points at the composition that
    # ships it properly.
    def dirty_message(pending, ahead, accepted, accepted_ahead, unreadable = [], conflict = nil)
      lines = [dirty_headline(pending.any? || ahead.any?,
                              accepted.any? || accepted_ahead.any?,
                              unreadable.any?)]
      if pending.any?
        lines << "  #{pending.size} task(s) already riding `release` (swept or QA-green), pending ship:"
        lines.concat(task_lines(pending))
      end
      lines << "  Repo(s) ahead of main: #{repo_summary(ahead)}" if ahead.any?
      if accepted.any?
        lines << "  #{accepted.size} task(s) reviewed and parked on `accepted`, pending the sweep:"
        lines.concat(task_lines(accepted))
      end
      if accepted_ahead.any?
        lines << "  Repo(s) with `accepted` ahead of `release`: #{repo_summary(accepted_ahead)}"
      end
      if accepted.any? || accepted_ahead.any?
        lines << "  The sweep promotes ALL of `accepted` onto `release`, so that work would ride out too."
      end
      if unreadable.any?
        lines << "  Rung(s) that could NOT be read (a failed read is not a clean read): " \
                 "#{unreadable.map { |u| "#{u['repo']}/#{u['rung']}" }.join(', ')}"
        lines << "  Fetch those repos (or fix the missing branch), then re-run the guard."
      end
      lines << "  ⚠ #{conflict}" if conflict
      lines << "  Expediting one task now would DRAG that pending work to production."
      lines << "  → Ship the WHOLE release instead: run the `Alex Heartbeat` `full-cycle` launcher."
      lines.join("\n")
    end

    # Name the rung(s) that are dirty, so the operator knows where to look
    # instead of re-deriving it from the list below.
    def dirty_headline(release_dirty, accepted_dirty, unreadable = false)
      rungs = []
      rungs << "accepted ≠ release" if accepted_dirty
      rungs << "release ≠ main" if release_dirty
      rungs << "a rung could not be read" if unreadable
      "✗ deploy-with-task refused: the `accepted → release → main` ladder is NOT clean (#{rungs.join(', ')})."
    end

    # The accepted rung's two signals should agree; when they do not, say which
    # way. Both directions still REFUSE (fail-closed) — this only explains the
    # disagreement, because "which record is wrong" is the actionable part.
    def accepted_signal_conflict(accepted, accepted_ahead, git_measured, attributed = false)
      return nil if attributed
      return nil unless git_measured
      return nil if accepted.any? == accepted_ahead.any?

      if accepted_ahead.any?
        "the two `accepted` signals DISAGREE: git says `accepted` carries commits " \
          "(#{repo_summary(accepted_ahead)}), but NO task is stamped merged:\"accepted\". " \
          "Either a review skipped the stamp, or something landed on `accepted` with no task " \
          "behind it. Trust the git read and reconcile the board before expediting."
      else
        "the two `accepted` signals DISAGREE: #{accepted.size} task(s) are stamped " \
          "merged:\"accepted\", but no repo's `accepted` is ahead of `release`. " \
          "Either the sweep already promoted them and the stamp is stale, or the stamp names " \
          "the wrong rung. Reconcile the board before expediting."
      end
    end

    def normalize_tasks(tasks)
      Array(tasks).map { |t| { "slug" => value(t, "slug"), "title" => value(t, "title") } }
    end

    def normalize_unreadable(repos)
      Array(repos).map { |r| { "repo" => value(r, "repo"), "rung" => value(r, "rung") } }
    end

    def task_lines(tasks)
      tasks.map { |t| "    - #{t['slug']}#{t['title'].to_s.empty? ? '' : " — #{t['title']}"}" }
    end

    def ahead_repos(states)
      Array(states)
        .map { |s| { "repo" => value(s, "repo"), "ahead" => value(s, "ahead").to_i } }
        .select { |s| s["ahead"].positive? }
    end

    def repo_summary(repos)
      repos.map { |r| "#{r['repo']} (+#{r['ahead']})" }.join(", ")
    end

    # Read a string-or-symbol key off a hash; "" for a missing key.
    def value(hash, key)
      return "" unless hash.respond_to?(:[])

      v = hash[key]
      v = hash[key.to_sym] if v.nil?
      v.nil? ? "" : v
    end
  end
end
