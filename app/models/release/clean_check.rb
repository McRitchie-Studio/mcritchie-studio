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
  # to look clean. The release rung reports its disagreement the same way
  # (`release_signal_conflict`), where board-dirty + git-clean is the signature of
  # an INTERRUPTED SHIP — code already fast-forwarded to `main`, board unstamped.
  #
  # AND THE VERDICT NAMES THE SIGNAL IT MEASURED. Every line here reports which of
  # the four reads fired; it never renders a board conclusion as a tree relation.
  # See dirty_headline for the defect that rule was written for.
  #
  # A read that FAILED is not a read that came back clean. A rung whose count
  # could not be measured (`unreadable_repos`) is dirty too — silently skipping an
  # unmeasurable repo is the same shape of bug as never measuring the rung at all.
  # And a PARTIAL read cannot SPEAK for the rung: "the trees are identical" is a
  # claim about every repo, so a conflict sentence that makes one is withheld
  # unless every repo reported. See `rung_read` — a partial read passing as a full
  # one is how the guard would state, with specifics, that the operator's code is
  # already in production while it had not looked at half the repos.
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
    #   could not be read at all (missing branch, failed rev-list). Always dirty —
    #   AND they mark the rung's read PARTIAL, which is how a conflict sentence
    #   knows not to speak for repos nobody looked at (see `rung_read`).
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
    #   "release_signal_conflict" => nil, or a sentence naming the release rung's
    #                             board-vs-git disagreement — tasks still recorded
    #                             as riding `release` with release == main, i.e. an
    #                             INTERRUPTED SHIP whose code is already in prod
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
      # How much of each rung's git read actually landed — :unmeasured, :partial or
      # :complete. An unmeasured signal can neither corroborate nor contradict the
      # stamp, and a PARTIAL one cannot carry a universal claim about the trees.
      # See rung_read and the two conflict methods.
      conflict = accepted_signal_conflict(accepted, measured_ahead,
                                          rung_read(accepted_states, unreadable), attributed)
      release_conflict = release_signal_conflict(pending, ahead, rung_read(repo_states, unreadable))

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
        "release_signal_conflict" => release_conflict,
        "message" => clean ? clean_message(slug, attributed_ahead) : dirty_message(
          pending, ahead, accepted, accepted_ahead, unreadable, conflict, release_conflict
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
    def dirty_message(pending, ahead, accepted, accepted_ahead, unreadable = [], conflict = nil,
                      release_conflict = nil)
      lines = [dirty_headline(pending, ahead, accepted, accepted_ahead, unreadable)]
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
      lines << "  ⚠ #{release_conflict}" if release_conflict
      lines << "  ⚠ #{conflict}" if conflict
      lines << "  Expediting one task now would DRAG that pending work to production."
      lines << "  → Ship the WHOLE release instead: run the `Alex Heartbeat` `full-cycle` launcher."
      lines.join("\n")
    end

    # Name the rung(s) that are dirty, so the operator knows where to look
    # instead of re-deriving it from the list below.
    #
    # REPORT THE SIGNAL THAT WAS MEASURED, never a relation that was not read.
    # Each rung is judged by TWO signals (board + git), and this line used to
    # collapse them with an `||` and then label the result with the GIT relation
    # — `release ≠ main`, `accepted ≠ release`. So a rung that was dirty on the
    # BOARD signal alone asserted a TREE relation nobody had measured, and during
    # rel-20260812-3f1f9b it asserted one that was FALSE: all three rungs were
    # identical (`git ls-remote` had every repo at one SHA) while three tasks were
    # still recorded as riding `release`. The operator re-fetched, learned
    # nothing, and had to go to `git ls-remote` to find out the line was wrong.
    #
    # So each rung names its signals separately (joined by "; "). The two agree in
    # the normal case and read the same; when they DISAGREE that is itself the
    # finding — see release_signal_conflict — and the headline now shows it
    # instead of hiding it behind a relation.
    def dirty_headline(pending, ahead, accepted, accepted_ahead, unreadable = [])
      rungs = []
      rungs << accepted_rung_reason(accepted, accepted_ahead) if accepted.any? || accepted_ahead.any?
      rungs << release_rung_reason(pending, ahead) if pending.any? || ahead.any?
      rungs << "a rung could not be read" if unreadable.any?
      "✗ deploy-with-task refused: the `accepted → release → main` ladder is NOT clean (#{rungs.join(', ')})."
    end

    # The `accepted` rung's reason, by measured signal: the board count, the git
    # relation, or both.
    def accepted_rung_reason(accepted, accepted_ahead)
      parts = []
      parts << "#{accepted.size} task(s) stamped merged:\"accepted\"" if accepted.any?
      parts << "accepted ≠ release" if accepted_ahead.any?
      parts.join("; ")
    end

    # The `release` rung's reason, by measured signal.
    def release_rung_reason(pending, ahead)
      parts = []
      parts << "#{pending.size} task(s) still recorded as riding `release`" if pending.any?
      parts << "release ≠ main" if ahead.any?
      parts.join("; ")
    end

    # HOW MUCH OF A RUNG'S GIT READ LANDED. A conflict sentence is only as sound
    # as the read behind it, and the two failure modes are different:
    #   :unmeasured — no repo was read at all (a --dry-run takes no fetch). A
    #                 signal never taken can neither agree nor disagree.
    #   :partial    — some repo could not be read (`unreadable_repos`). The read
    #                 RAN, so a positive count it returned is real, but it cannot
    #                 support a claim about every repo.
    #   :complete   — every repo reported a count.
    #
    # COMPLETENESS IS DERIVED FROM THE REPO SETS, NOT FROM THE `rung` LABEL. A
    # repo that failed SOME read is complete on THIS rung only if it still
    # produced a reading HERE. That is label-free on purpose: one unreadable entry
    # can stand for both rungs at once — bin/release records a missing checkout as
    # a single row labelled `accepted (no checkout at …)` though neither rung was
    # read — so matching on the label would rebuild this very bug on a string
    # compare, and it keeps a failure on one rung from muting the other.
    def rung_read(states, unreadable)
      measured = Array(states).map { |s| value(s, "repo").to_s }
      return :partial if Array(unreadable).any? { |u| !measured.include?(value(u, "repo").to_s) }
      return :unmeasured if measured.empty?

      :complete
    end

    # The accepted rung's two signals should agree; when they do not, say which
    # way. Both directions still REFUSE (fail-closed) — this only explains the
    # disagreement, because "which record is wrong" is the actionable part.
    #
    # The two directions need DIFFERENT amounts of read behind them, so the
    # completeness rule is applied per branch rather than at the top.
    def accepted_signal_conflict(accepted, accepted_ahead, git_read, attributed = false)
      return nil if attributed
      return nil if git_read == :unmeasured
      return nil if accepted.any? == accepted_ahead.any?

      if accepted_ahead.any?
        # EXISTENTIAL over the git read — "git says `accepted` carries commits"
        # names repos it actually measured, and a repo that went unread cannot
        # falsify a count that came back positive. A partial read still earns this.
        "the two `accepted` signals DISAGREE: git says `accepted` carries commits " \
          "(#{repo_summary(accepted_ahead)}), but NO task is stamped merged:\"accepted\". " \
          "Either a review skipped the stamp, or something landed on `accepted` with no task " \
          "behind it. Trust the git read and reconcile the board before expediting."
      else
        # UNIVERSAL over the git read — "NO repo's `accepted` is ahead" is a claim
        # about EVERY repo, and a partial read cannot make it. See
        # release_signal_conflict for what asserting it anyway costs.
        return nil unless git_read == :complete

        "the two `accepted` signals DISAGREE: #{accepted.size} task(s) are stamped " \
          "merged:\"accepted\", but no repo's `accepted` is ahead of `release`. " \
          "Either the sweep already promoted them and the stamp is stale, or the stamp names " \
          "the wrong rung. Reconcile the board before expediting."
      end
    end

    # The release rung's two signals, like the accepted rung's — but the
    # disagreement that matters here points the OTHER way, and it is the most
    # consequential state this guard can observe.
    #
    # BOARD-DIRTY + GIT-CLEAN means tasks are still recorded as riding `release`
    # while `release` and `main` are IDENTICAL. That is what an INTERRUPTED SHIP
    # looks like: the fast-forward to `main` already landed — THE CODE IS ALREADY
    # IN PRODUCTION — and the board was never stamped. It is exactly the moment an
    # operator most needs to be told the code is out, and exactly the moment the
    # old headline said `release ≠ main` and sent them to re-fetch a tree that was
    # never behind (rel-20260812-3f1f9b).
    #
    # The guard still REFUSES either way (fail-closed, unchanged) — the board says
    # work is unaccounted for, and that is reason enough not to expedite. This only
    # explains WHICH record to go fix, the same job accepted_signal_conflict does.
    #
    # AND IT DEMANDS A COMPLETE READ. "the trees are identical" is a claim about
    # EVERY repo, so a PARTIAL read cannot make it — yet the check used to fire on
    # `repo_states.any?`, which one readable repo satisfies while another sits in
    # `unreadable_repos`. That produced the worst output this module can emit: a
    # confident, specific, WRONG statement that the operator's code is already in
    # production, at the exact moment they are deciding whether to ship. Withhold
    # the explanation instead; the rung is dirty either way (an unreadable repo is
    # dirty on its own), so nothing is lost but a sentence that was not earned.
    def release_signal_conflict(pending, ahead, git_read)
      return nil unless git_read == :complete
      return nil unless pending.any? && ahead.empty?

      "the two `release` signals DISAGREE: #{pending.size} task(s) are still recorded as riding " \
        "`release`, but NO repo's `release` is ahead of `main` — the trees are identical. That is " \
        "what an INTERRUPTED SHIP looks like: the fast-forward to `main` already landed, so this " \
        "code may ALREADY BE IN PRODUCTION and only the board stamp is missing. Confirm with " \
        "`git ls-remote --heads origin main release`, then reconcile the board before expediting."
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
