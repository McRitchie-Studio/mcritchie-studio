class Release
  # Pure decision logic for the CLEAN-RELEASE GUARD that Avi's `deploy-with-task`
  # act runs FIRST. Like Release::Cli / MergePlan / ShipSequence
  # this is deliberately IO-free and Rails-free: it takes the already-gathered
  # board + git state in and returns the clean/dirty verdict plus the
  # operator-facing message out, so the "is it safe to expedite one task" decision
  # lives in ONE unit-tested place. (bin/release `require_relative`s this file
  # directly, so it must load standalone with no Rails dependency.)
  #
  # WHY IT EXISTS: `deploy-with-task` expedites a SINGLE task to prod by
  # merging its PR into `release` and fast-forwarding `release → main`. That ff
  # drags along EVERYTHING already sitting on `release` ahead of `main` — i.e. any
  # OTHER task whose code already rides `release` but isn't `shipped`, whether
  # `assembled` (QA-green) or still `reviewed` with merged:"release" (swept, QA
  # in flight). So expediting
  # one task is only safe when `release == main` (nothing else is pending). On a
  # DIRTY release the guard REFUSES and OFFERS the `Alex Heartbeat` `full-cycle`
  # launcher (ship the WHOLE release) instead of silently shipping the pending work.
  #
  # It reads TWO independent signals and is FAIL-CLOSED — either one showing
  # pending work makes the release dirty:
  #   * board — tasks riding `release` pending ship: `assembled` (QA-green) plus
  #     `reviewed` with merged:"release" (swept by Avi, QA in flight).
  #   * git   — commits `origin/release` is ahead of `origin/main`, per repo.
  # Two signals catch each other's blind spots: a task stuck on the release with
  # no commits still trips the board signal; a stray commit pushed straight to
  # `release` with no task still trips the git signal.
  module CleanCheck
    module_function

    # pending_tasks: [{ "slug" =>, "title" => }, …] — tasks riding `release`
    #   pending ship (the board signal: `assembled`, plus `reviewed` with
    #   merged:"release"). String OR symbol keys tolerated.
    # repo_states:   [{ "repo" =>, "ahead" => Integer }, …] — commits
    #   origin/release is ahead of origin/main per release repo (the git signal);
    #   ahead == 0 means that repo's release == main.
    # Returns a JSON-friendly, string-keyed verdict:
    #   "clean"         => Boolean — release == main (safe to expedite one task)
    #   "pending_tasks" => the normalized pending tasks (empty when clean)
    #   "ahead_repos"   => the repos with ahead > 0 (empty when clean)
    #   "message"       => the operator-facing verdict line(s): a one-line OK when
    #                      clean, or the REFUSAL + `Alex Heartbeat` full-cycle OFFER
    #                      (listing the pending work) when dirty.
    def evaluate(pending_tasks: [], repo_states: [])
      pending = Array(pending_tasks).map do |t|
        { "slug" => value(t, "slug"), "title" => value(t, "title") }
      end
      ahead = Array(repo_states)
        .map { |s| { "repo" => value(s, "repo"), "ahead" => value(s, "ahead").to_i } }
        .select { |s| s["ahead"].positive? }

      clean = pending.empty? && ahead.empty?
      {
        "clean" => clean,
        "pending_tasks" => pending,
        "ahead_repos" => ahead,
        "message" => clean ? clean_message : dirty_message(pending, ahead)
      }
    end

    def clean_message
      "✓ release is clean (release == main) — safe to expedite one task with the `deploy-with-task` act."
    end

    # The refusal + the offer. Never silently drags the pending work to prod: it
    # names WHAT is pending and points at the composition that ships it properly.
    def dirty_message(pending, ahead)
      lines = ["✗ deploy-with-task refused: `release` is NOT clean (release ≠ main)."]
      if pending.any?
        lines << "  #{pending.size} task(s) already riding `release` (swept or QA-green), pending ship:"
        pending.each { |t| lines << "    - #{t['slug']}#{t['title'].to_s.empty? ? '' : " — #{t['title']}"}" }
      end
      if ahead.any?
        lines << "  Repo(s) ahead of main: #{ahead.map { |r| "#{r['repo']} (+#{r['ahead']})" }.join(', ')}"
      end
      lines << "  Expediting one task now would DRAG that pending work to production."
      lines << "  → Ship the WHOLE release instead: run the `Alex Heartbeat` `full-cycle` launcher."
      lines.join("\n")
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
