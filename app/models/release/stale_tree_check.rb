class Release
  # Pure decision logic for the STALE-TREE GATE that `bin/release prepare` runs
  # AFTER the accepted→release promote and BEFORE it publishes, gates, or deploys
  # anything. Like Release::CleanCheck / SweepPlan / ShipSequence this is
  # deliberately IO-free and Rails-free: it takes the already-gathered git state
  # in and returns the fresh/stale verdict plus the operator-facing message out.
  # (bin/release `require_relative`s this file directly, so it must load
  # standalone with no Rails dependency.)
  #
  # WHY IT EXISTS — the defect it was built for. `prepare` derives WHICH REPOS to
  # promote from BOARD STAMPS: the repos of sweep candidates stamped
  # merged:"accepted". A commit that reaches `accepted` with no such task behind
  # it — a conductor zap onto `accepted`, a hand-merge, a review whose `merged`
  # stamp never got written — is invisible to that derivation, so the promote is
  # SKIPPED for its repo. Everything downstream then runs happily on the OLD
  # tree: membership re-records, QA re-deploys the same SHA, the QA-green flip
  # lands, and prepare prints `✓ Assembled`. Measured in the wild (2026-08-11):
  # `accepted` at ed4d16a, `release` at b032e58, one commit stranded, QA serving
  # the previous tree, and BOTH sentences prepare printed were true — of a tree
  # that did not contain the fix.
  #
  # THE BUG WAS NEVER THE SKIPPED PROMOTE. It was the SUCCESS printed over it. A
  # sweep that cannot carry a commit is a normal, recoverable situation; a sweep
  # that reports a candidate assembled when the candidate does not contain the
  # work is a lie the operator has no way to see. So this gate does not try to
  # heal the promote — it ASSERTS THE EFFECT the promote was supposed to have and
  # REFUSES when the effect is missing.
  #
  # THE PROPERTY, stated once: for every three-rung repo the candidate is about
  # to deploy, `origin/release` must already contain `origin/accepted`. That is
  # the ONE thing that makes prepare's own output true. It is checked AFTER the
  # promote deliberately — a check placed before it would be re-deriving the
  # promote's own decision (the proxy), while a check placed after it measures
  # what actually landed, and so catches every cause at once: a repo the promote
  # never considered, a `gh pr merge` that reported success without landing, a
  # stamp nobody wrote, an assembled candidate no promote was even attempted for.
  #
  # WHY IT REFUSES INSTEAD OF RE-PROMOTING. Silently promoting `accepted` onto an
  # already-`assembled` candidate would be the convenient fix and it is the wrong
  # one. The sweep DOES legitimately grow a candidate when new REVIEWED work
  # arrives — those commits have tasks, become members, and ride a fresh pre-QA
  # gate and QA deploy, so the record keeps up with the tree. The commits this
  # gate finds are precisely the ones with NO task behind them. Promoting those
  # would move the tree while leaving the membership record complete-looking and
  # wrong: the release would say it contains T1 and T2, and the deployed tree
  # would also contain a change no G2 review ever saw and no member names.
  # Refusing costs the operator one hand-opened batch PR; re-promoting costs the
  # release record its meaning.
  #
  # A read that FAILED is not a read that came back clean (the same rule
  # Release::CleanCheck states for its rungs): an unreadable repo is STALE here,
  # never skipped. An unmeasurable rung and a rung nobody measured produce the
  # same silence, and that silence is what this whole family of bugs is made of.
  module StaleTreeCheck
    # The two rung names + the stamp value this message quotes. bin/release owns
    # top-level RELEASE_BRANCH / ACCEPTED_BRANCH / ACCEPTED_MERGED, and Rails
    # owns Release::BRANCH — but this file loads in BOTH worlds, and in the
    # Rails-free one `Release` is a bare class with no BRANCH at all. So it
    # carries its own copies rather than reaching for a constant that exists in
    # only one of them. Keep them in step with bin/release.rb:224 + :232 and
    # Release::BRANCH (app/models/release.rb:17).
    RELEASE_RUNG = "release"
    ACCEPTED_RUNG = "accepted"
    ACCEPTED_MERGED_STAMP = "accepted"

    module_function

    # accepted_states:  [{ "repo" =>, "ahead" => Integer }, …] — commits
    #   origin/accepted is ahead of origin/release, per repo the candidate is
    #   about to deploy, measured AFTER the promote. ahead == 0 means that repo's
    #   `release` already carries everything on `accepted`. Pass EVERY repo
    #   measured, ahead == 0 included.
    # unreadable_repos: [{ "repo" =>, "rung" => }, …] — repos whose count could
    #   not be read at all (missing branch, missing checkout, failed rev-list).
    #   Always stale.
    # stranded_commits: { "<repo>" => [{ "sha" =>, "subject" => }, …] } — the
    #   actual commits sitting on `accepted` and missing from `release`, newest
    #   FIRST. Optional: without it the refusal still names the repo and the
    #   count, it just cannot print the SHAs or pin the recovery merge.
    # repo_nwo:         { "<repo>" => "owner/name" } — for the `gh` recovery
    #   commands. A missing entry drops `--repo` from the printed command.
    # release_slug / release_state: the candidate being prepared, for the message.
    #
    # Returns a JSON-friendly, string-keyed verdict:
    #   "fresh"            => Boolean — every measured repo's `release` contains
    #                         `accepted`, and every repo WAS measured
    #   "stale_repos"      => repos whose `accepted` is ahead (empty when fresh)
    #   "unreadable_repos" => rung reads that failed (empty when fresh)
    #   "message"          => the operator-facing verdict: a short OK when fresh,
    #                         or the REFUSAL naming the stranded commits and the
    #                         exact recovery when stale.
    def evaluate(accepted_states: [], unreadable_repos: [], stranded_commits: {},
                 repo_nwo: {}, release_slug: nil, release_state: nil, task_index: {})
      # Reuse Release::CleanCheck's rung comparison rather than re-deriving it.
      # Two implementations of "which repos are ahead" is exactly how the ladder
      # guard and this gate would drift apart, and they must agree: they are
      # reading the SAME rung with the same fail-closed rule.
      stale      = Release::CleanCheck.ahead_repos(accepted_states)
      unreadable = Release::CleanCheck.normalize_unreadable(unreadable_repos)
      fresh      = stale.empty? && unreadable.empty?

      {
        "fresh" => fresh,
        "stale_repos" => stale,
        "unreadable_repos" => unreadable,
        "message" => if fresh
                       fresh_message(accepted_states)
                     else
                       stale_message(stale, unreadable, stranded_commits, repo_nwo,
                                     release_slug, release_state, task_index)
                     end
      }
    end

    # The OK line. Names the repos it actually verified, so a pass is evidence
    # the check RAN over the right scope rather than a line that prints whether
    # or not anything was measured.
    def fresh_message(accepted_states)
      repos = Array(accepted_states).map { |s| Release::CleanCheck.value(s, "repo") }.reject { |r| r.to_s.empty? }
      scope = repos.empty? ? "no three-rung repo in the deploy plan" : repos.join(", ")
      "✓ `#{RELEASE_RUNG}` carries every `#{ACCEPTED_RUNG}` commit (#{scope}) — " \
        "the candidate's tree is current."
    end

    # The refusal. It must do three things the old silent success did not: say
    # the tree is stale, NAME the commits that are missing from it, and hand back
    # the exact recovery with the repo and SHAs filled in. A refusal that does not
    # name its remedy just moves the confusion.
    def stale_message(stale, unreadable, stranded_commits, repo_nwo, release_slug, release_state,
                      task_index = {})
      rel = release_slug.to_s.empty? ? "the candidate" : release_slug.to_s
      rel += " (#{release_state})" unless release_state.to_s.empty?

      lines = ["✗ prepare refused: #{rel} would deploy a tree that does NOT contain `#{ACCEPTED_RUNG}`."]
      stale.each { |repo| lines.concat(stale_repo_lines(repo, stranded_commits, task_index)) }
      unreadable.each do |u|
        lines << "  #{u['repo']}: the `#{u['rung']}` rung could NOT be read — a failed read is not a clean read, " \
                 "so it counts as stale. Fetch the repo (or fix the missing branch), then re-run."
      end
      lines << "  Deploying now would print `✓ Assembled` over a tree missing that work — the exact " \
               "false success this gate exists to stop."
      lines << "  NOTHING was published, gated, or deployed; members keep their stage."
      lines << "  The candidate is NOT untouched, though: membership was already recorded (sweep! runs before " \
               "this gate), and in a multi-repo release a partial batch promote may already have landed. " \
               "Re-running after the recovery below re-uses that record rather than double-recording."
      lines.concat(why_lines)
      lines.concat(assembled_lines) if release_state.to_s == "assembled"
      lines.concat(lost_stamp_lines(stale, stranded_commits, task_index))
      lines.concat(recovery_lines(stale, stranded_commits, repo_nwo, release_slug))
      lines.join("\n")
    end

    # One stale repo, named with its count and — when the caller gathered them —
    # the actual commits. The count alone is not enough: "1 commit behind" sends
    # the operator to go look it up, and the whole point of the refusal is that
    # it hands over what it already knows.
    def stale_repo_lines(repo, stranded_commits, task_index = {})
      slug    = repo["repo"].to_s
      ahead   = repo["ahead"].to_i
      commits = commits_for(stranded_commits, slug)
      header  = "  #{slug}: #{ahead} commit#{ahead == 1 ? '' : 's'} stranded on `#{ACCEPTED_RUNG}`, " \
                "missing from `#{RELEASE_RUNG}`:"

      if commits.empty?
        return [header,
                "    - (commit list unavailable — run " \
                "`git log --oneline origin/#{RELEASE_RUNG}..origin/#{ACCEPTED_RUNG}` in #{slug})"]
      end

      [header] + commits.flat_map do |c|
        subject = Release::CleanCheck.value(c, "subject").to_s
        line = "    - #{Release::CleanCheck.value(c, 'sha')}#{subject.empty? ? '' : " #{subject}"}"
        [line] + attribution_lines(subject, task_index)
      end
    end

    # ATTRIBUTION. The merge subject carries the branch, and a task's branch is
    # seeded from its slug, so a commit that came from a feat branch names its
    # own task. When that task exists but carries no `merged` stamp, this is a
    # LOST STAMP — a bookkeeping failure with a two-command repair — not the
    # unattributable orphan the generic text describes. Anything that does not
    # resolve prints nothing extra, so the refusal reads exactly as it did.
    def attribution_lines(subject, task_index)
      result = Release::MergeSubject.attribute(subject, task_index)
      case result[:kind]
      when :lost_stamp
        ["        \u21B3 task `#{result[:slug]}` EXISTS (stage: #{result[:stage]}) with NO `merged` " \
         "stamp — this is a LOST STAMP, not an unattributable orphan.",
         "          repair: #{Release::MergeSubject.lost_stamp_repair(result[:slug])}"]
      when :stamped
        ["        \u21B3 task `#{result[:slug]}` exists and is stamped " \
         "merged:\"#{result[:merged]}\" — already attributed."]
      else
        []
      end
    end

    # When EVERY stranded commit resolves to a lost stamp, say so once rather
    # than leaving the reader to infer it from the per-commit lines. The refusal
    # itself is unchanged — this only narrows WHICH recovery applies.
    def lost_stamp_lines(stale, stranded_commits, task_index)
      all = stale.flat_map { |repo| commits_for(stranded_commits, repo["repo"].to_s) }
      return [] if all.empty?

      kinds = all.map do |c|
        Release::MergeSubject.attribute(Release::CleanCheck.value(c, "subject").to_s, task_index)[:kind]
      end
      return [] unless kinds.any? && kinds.all?(:lost_stamp)

      ["", "  EVERY stranded commit above is a LOST STAMP: review landed the PR on `#{ACCEPTED_RUNG}` but " \
           "its task was never stamped, so the promote could not see it. Stamping the task(s) and re-running " \
           "`bin/release prepare` is the whole repair — you do NOT need the hand-landed batch PR below, " \
           "which is for a commit no task owns."]
    end

    # String OR symbol repo keys tolerated, matching CleanCheck#value's policy —
    # the CLI hands string keys, the unit tests are easier to read with symbols.
    def commits_for(stranded_commits, slug)
      Array(stranded_commits[slug] || stranded_commits[slug.to_sym])
    end

    # WHY the promote missed it. Without this the operator reads the refusal as a
    # tooling malfunction and re-runs, which changes nothing.
    def why_lines
      ["  WHY the promote did not carry it: prepare derives the repos to promote from BOARD STAMPS — the " \
       "sweep candidates stamped merged:\"#{ACCEPTED_MERGED_STAMP}\". A commit that reached " \
       "`#{ACCEPTED_RUNG}` with no such task behind it (a conductor zap, a hand-merge, a review whose " \
       "stamp never landed) is invisible to that derivation."]
    end

    # The assembled case gets one extra paragraph, because "why won't you just
    # promote it for me" is the reasonable question and it deserves the answer
    # in the tool rather than in a design doc.
    def assembled_lines
      ["  This candidate is already `assembled` (QA-green). prepare will NOT silently promote onto it: the " \
       "recorded QA verdict describes the tree QA actually ran, and moving `#{RELEASE_RUNG}` underneath it " \
       "would leave that verdict describing a tree nobody tested. Landing the batch PR and re-running prepare " \
       "re-gates and re-deploys QA over the NEW tree — the honest version of the same outcome."]
    end

    # The recovery, with the repo and the SHAs filled in — the same path the
    # operator already walks by hand today, minus the guessing.
    def recovery_lines(stale, stranded_commits, repo_nwo, release_slug)
      lines = ["  → RECOVER — land the stranded work on `#{RELEASE_RUNG}`, then re-run:"]
      stale.each do |repo|
        slug = repo["repo"].to_s
        nwo  = (repo_nwo[slug] || repo_nwo[slug.to_sym]).to_s
        scope = nwo.empty? ? "" : " --repo #{nwo}"
        title = release_slug.to_s.empty? ? "Promote #{ACCEPTED_RUNG} → #{RELEASE_RUNG}" \
                                         : "Promote #{ACCEPTED_RUNG} → #{RELEASE_RUNG} (#{release_slug})"
        # Pin the merge at the NEWEST stranded commit (the accepted head the
        # recovery PR's CI will have run against), so a push landing between the
        # CI verdict and the merge is rejected instead of riding in unverified.
        head = commits_for(stranded_commits, slug).first
        pin  = head ? " --match-head-commit #{Release::CleanCheck.value(head, 'sha')}" : ""
        lines << "      # #{slug}"
        lines << "      gh pr create#{scope} --base #{RELEASE_RUNG} --head #{ACCEPTED_RUNG} " \
                 "--title #{title.inspect} --body \"Stranded #{ACCEPTED_RUNG} work.\""
        lines << "      #   … watch that PR's CI to green …"
        lines << "      gh pr merge#{scope} <pr-url> --merge#{pin}"
      end
      lines << "      bin/release prepare"
      lines << "  The re-run promotes nothing new (the merge already landed it), re-runs the pre-QA gate, and " \
               "re-deploys QA over the tree that now contains the work — so the ✓ describes what shipped."
      lines
    end
  end
end
