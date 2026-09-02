# frozen_string_literal: true

# OpenPrGuard — refuse to archive a task that still has an OPEN PR, and name it.
#
# THE MEASURED CASE (2026-09-01, found by auditing the open-PR backlog).
# studio-engine #245, "Move the Solana sign-in button behind an auth credential
# slot": opened 2026-08-31 against `accepted`, carrying 169 lines of new tests and
# a fixture-based credential-slot pattern. Its task, `move-web3-modals-to-solana`,
# was ARCHIVED on 2026-09-01 at 03:12Z. The blocker written into the PR's own body
# — "merge AFTER solana-studio#9 and after that gem publishes" — was DISCHARGED
# when solana-studio #9 merged later that same day. So the PR became mergeable in
# principle a day after its task was archived, and nobody was watching either side.
# It surfaced a month later, and only because a human asked for a backlog audit.
#
# ═══ THE INVARIANT ═══
#
# POSITIVE, asserted, and deliberately narrower than the holder gate's:
#
#   ARCHIVE ONLY WHAT LEAVES NO WORK UNRESOLVED.
#
# "UNRESOLVED" is the load-bearing word, and it is a DIFFERENT harm from the one
# lib/archive_holder_guard.rb exists to prevent. Read them together or this file
# looks like it contradicts that one:
#
#   ArchiveHolderGuard  archiving DESTROYS uncommitted work in a desk.
#                       The harm is IRREVERSIBLE. No artifact can reconstruct it.
#   OpenPrGuard         archiving ORPHANS a PR that is already durable.
#                       The harm is that the work goes QUIET — neither merged nor
#                       closed, with no board state describing it — and nothing
#                       downstream will ever raise its hand about it again.
#
# The holder gate says a PR "survives the archive untouched and must not hold the
# gate", and that is exactly right FOR ITS QUESTION: a PR is not work an archive can
# destroy. This gate asks the other question. A PR survives the archive OPEN and
# UNWATCHED, and "survives" is not "is resolved".
#
# ═══ WHY THE FIX IS NOT "CLOSE THE PR ON ARCHIVE" ═══
#
# Archiving is how an operator DROPS work, and a dropped branch may hold the only
# copy of a design — #245 above is 169 lines of tests nobody rewrote. And `archived`
# is not a lock: a task an operator dropped has been un-archived and shipped by a
# later session before. So closing the PR would destroy an option the board has
# repeatedly needed to take back.
#
# The honest behaviour is the holder gate's posture, pointed at a different fact:
# REFUSE, NAME each open PR and its state, and let a human decide close-vs-revive.
#
# ═══ THE WHOLE SET, NOT THE PRIMARY ═══
#
# `refs` reads `devops.pr_url` AND every value in `devops.pr_urls`. A check reading
# only the singular is the trap this defect sets: `pr_url` holds ONE url, so a task
# naming two repos records its second repo's PR only in the map, and a task whose
# singular names the MERGED repo while the map holds the OPEN one passes clean.
# `move-web3-modals-to-solana` names both solana-studio (#9, MERGED) and
# studio-engine (#245, OPEN).
#
# IT DELIBERATELY DIFFERS FROM Task#release_pr_urls, which collapses to one PR per
# repo with the singular winning. That method answers "which PR does the release act
# on for this repo" — one repo, one authoritative PR, by design. This one answers
# "which PRs would this archive leave unresolved", and for THAT question a superseded
# map entry pointing at a still-open PR is a real orphan, not a stale duplicate.
# Collapsing here would drop it. Same data, two questions; the folds are not
# interchangeable and must not be "tidied" into one.
#
# ═══ WHY AN UNREADABLE PR STATE WARNS RATHER THAN REFUSING ═══
#
# THIS IS THE ONE PLACE THIS FILE DEPARTS FROM THE HOLDER GATE, and the departure is
# principled rather than convenient. bin/task's `archive_holder_facts` rescues in the
# PROTECTIVE direction because "a check that blew up has told us nothing, and nothing
# must never authorize a destructive act". That is right where the loss is
# irreversible. Here it is not:
#
#   1. THE HARM IS RECOVERABLE. The PR is durable on GitHub. An archive we let
#      through wrongly leaves a findable orphan, and `bin/task orphan-prs` — shipped
#      with this guard — is what finds it. The holder gate has no such second look:
#      uncommitted work it lets through is gone.
#   2. REFUSING HERE WOULD REFUSE CONSTANTLY. The GitHub App installation token on
#      this machine expires ABOUT HOURLY BY DESIGN, so an unreadable `gh` is the
#      ROUTINE state, not the exceptional one. A gate that refuses on it refuses most
#      archives on most days.
#   3. AND THAT KILLS THE GATE. lib/archive_holder_guard.rb measured this exact
#      failure: its first cut refused 31 of 34 live tasks, and its own docblock names
#      the outcome — "a guard that refuses everything is uninstalled within a week,
#      and then it protects nothing". `--force` becomes muscle memory and the refusal
#      that matters is waved through with the rest.
#
# So the unknown WARNS, loudly, naming which PR could not be read and how to fix it.
# What it must never do is DRESS ITSELF AS THE REFUSAL: `unreadable_warning` says the
# check could not be completed, and never that a PR is open. Claiming a fact the
# check failed to establish is how a reader stops trusting the guard entirely.
module OpenPrGuard
  # github.com/<owner>/<repo>/pull/<n> — owner/repo captured together because that
  # is the `--repo` argument `gh` takes.
  PR_URL_PATTERN = %r{github\.com/([^/]+/[^/]+)/pull/(\d+)}

  # Already `archived` — a re-archive is idempotent and must not newly refuse.
  #
  # `shipped` IS DELIBERATELY ABSENT, unlike ArchiveHolderGuard::CONCLUDED_STAGES.
  # That gate skips shipped because merged code leaves nothing uncommitted to
  # destroy, which is true. It says nothing about whether every PR the task names
  # actually landed — the `merged` stamp is per-TASK while PRs are per-REPO, so a
  # multi-repo task reaches `shipped` on its primary while a sibling repo's PR is
  # still open. That is the population this gate exists for, and skipping it here
  # would exempt the shape most likely to strand.
  CONCLUDED_STAGES = %w[archived].freeze

  # Grades on which the archive PROCEEDS. A positive allowlist, so a grade added
  # later must be admitted on purpose rather than permitted by omission.
  PERMITTED = %i[concluded none clear unreadable].freeze

  # The PR states an override abandons. `:unknown` rides with `:open` because a
  # state we could not read is a state we could not establish as resolved — the
  # same asymmetry `state_of` applies, carried through to the receipt.
  ABANDONED_STATES = %i[open unknown].freeze

  # The devops list key that records a deliberate abandonment. It MUST be a
  # storable name in Task::DEVOPS_LIST_KEYS or the record silently evaporates —
  # `normalize_devops_metadata` drops any key outside DEVOPS_KEYS and the caller
  # still gets a 200. That is the failure mode `agent_slug` had inside
  # ArchiveHolderGuard::PAINT_KEYS: a key list nobody can populate is a promise the
  # gate cannot keep. bin/task reads the record BACK after the write for the same
  # reason.
  RECORD_KEY = "abandoned_prs"

  module_function

  # Every PR this task names — `devops.pr_url` and every `devops.pr_urls` value —
  # as [{ repo:, number:, url: }], de-duplicated by repo+number and stably ordered.
  #
  # The UNION, not the per-repo collapse. See "THE WHOLE SET" above.
  def refs(devops)
    devops ||= {}
    map = devops["pr_urls"]
    urls = [devops["pr_url"]] + (map.is_a?(Hash) ? map.values : Array(map))
    urls.filter_map { |url| ref_for(url) }.uniq { |ref| [ref[:repo], ref[:number]] }
  end

  # One url → { repo:, number:, url: }, or nil when it names no PR.
  def ref_for(url)
    text = url.to_s.strip
    match = PR_URL_PATTERN.match(text)
    return nil unless match

    { repo: match[1], number: match[2], url: text }
  end

  # GitHub's `state` string → our vocabulary. Anything we do not recognise is
  # :unknown, never a default of :merged or :closed — an unrecognised value is an
  # unread fact, and reading it as "resolved" is the direction that strands work.
  # Same allowlist posture bin/devops-reconcile takes.
  def state_of(raw)
    case raw.to_s.strip.upcase
    when "OPEN"   then :open
    when "MERGED" then :merged
    when "CLOSED" then :closed
    else :unknown
    end
  end

  # The grade for one archive. PURE: every fact is passed in. The CLI resolves PR
  # states over the network and this decides on them, so the whole table is
  # exercisable at the unit tier with no repo, no board, and no `gh`.
  #
  #   prs:   [{ repo:, number:, url:, state: }] — `refs` enriched with a state.
  #   stage: the task's CURRENT stage, as a string.
  def decide(prs:, stage: nil)
    return :concluded if CONCLUDED_STAGES.include?(stage.to_s.strip)

    list = Array(prs)
    return :none if list.empty?
    return :open if open_prs(list).any?
    return :unreadable if unreadable_prs(list).any?

    :clear
  end

  def permitted?(grade)
    PERMITTED.include?(grade)
  end

  def open_prs(prs)
    Array(prs).select { |pr| pr[:state] == :open }
  end

  def unreadable_prs(prs)
    Array(prs).select { |pr| pr[:state] == :unknown }
  end

  # Every PR an override would ABANDON: the OPEN ones, AND the ones whose state
  # could not be read. `record` folds THIS list, never `open_prs`.
  #
  # THE MIRROR OF THE PREFIX BUG (see `abandonment_recorded?`), erring the SAFE way
  # and still wrong. On a roster of [OPEN, UNREADABLE] the refusal names both, one
  # `--force` abandons both, and a receipt written only for the open one leaves the
  # unreadable one reporting as ORPHANED — forgotten — when it was dropped by the
  # same deliberate keystroke. Measured 2026-09-02: 2 PRs in, 1 receipt out.
  #
  # An unreadable PR ALONE never reaches here: :unreadable is PERMITTED, so that
  # archive proceeds with a warning and nothing is abandoned by anybody. This list
  # only matters once an OPEN PR has already forced the operator to decide, and at
  # that point the unreadable sibling is being dropped by the same choice.
  def abandoned_prs(prs)
    Array(prs).select { |pr| ABANDONED_STATES.include?(pr[:state]) }
  end

  # --- refusal + warning ---------------------------------------------------------

  # The message ONE grade carries, or nil when that grade has nothing to say.
  #
  # THE GRADE PICKS THE MESSAGE, in one place, because that is what makes the
  # completeness property assertable: a grade added to `decide` and not answered
  # here returns nil, and nil is a fact a test can see. The property test that
  # shipped with this guard could not see it — it derived the grade list from the
  # real predicate, then built its assertion from a hardcoded roster and never
  # passed `grade` into anything, so every unpermitted grade rendered the same
  # open-PR refusal and the file stayed green with the property unexercised.
  #
  # `:unreadable` is PERMITTED and still has a message. Permission and silence are
  # different questions, and the caller asks them separately.
  def message_for(grade:, slug:, stage:, prs:)
    case grade
    when :open       then refusal(slug: slug, stage: stage, prs: prs)
    when :unreadable then unreadable_warning(slug: slug, prs: prs)
    end
  end

  # NAME EVERY PR AND ITS STATE, not just the open ones. The operator's next move is
  # close-vs-revive, and that decision is made against the whole set: on
  # `move-web3-modals-to-solana` it is the MERGED sibling (solana-studio #9) that
  # tells them #245's stated blocker has already been discharged. Printing only the
  # open PR would hand them half the evidence.
  def refusal(slug:, stage:, prs:)
    open = open_prs(prs)
    unreadable = unreadable_prs(prs)
    plural = open.size == 1 ? "an OPEN PR" : "#{open.size} OPEN PRs"

    <<~TEXT.rstrip
      ⚠  REFUSING to archive #{slug} — it is #{stage}, and it still has #{plural}.

      #{roster(prs)}
      #{unreadable_note(unreadable)}
         Archiving does not close these. It leaves them OPEN and UNWATCHED: neither merged
         nor closed, with no board state describing them, and nothing downstream that will
         raise its hand about them again. On 2026-09-01 exactly this stranded studio-engine
         #245 — 169 lines of tests whose stated blocker was discharged the very next day —
         and it surfaced a month later only because a human audited the backlog.

         Resolve each PR, or decide to drop it:
           gh pr view <n> --repo <owner/repo>       # is it still wanted?
           gh pr merge <n> --repo <owner/repo>      # land it
           gh pr close <n> --repo <owner/repo>      # drop it deliberately
         Then archive. To archive and ABANDON the open PRs — recorded on the task as a
         deliberate choice, so a later reader knows they were dropped and not forgotten:
           bin/task move #{slug} archived --force
    TEXT
  end

  # The check could not be completed. It says SO, and says nothing about whether the
  # PR is open — that is the fact we just failed to establish. A warning that
  # borrowed the refusal's confidence would be a lie in the one direction that costs
  # the guard its credibility.
  def unreadable_warning(slug:, prs:)
    unreadable = unreadable_prs(prs)
    lines = unreadable.map { |pr| "     #{pr[:repo]}##{pr[:number]}  #{pr[:url]}" }.join("\n")

    <<~TEXT.rstrip
      warning: #{slug}: could not read the state of #{unreadable.size} PR(s) — archiving anyway.
      #{lines}
         This is NOT a finding that they are open; it is a check that did not complete.
         The usual cause is a stale GitHub App token (they expire about hourly by design):
           eval "$(bin/gh-auth-refresh --export)"
         Any orphan this lets through stays findable: bin/task orphan-prs
    TEXT
  end

  # One line per PR: repo#number, its state, and the url the operator will click.
  def roster(prs)
    Array(prs).map do |pr|
      "     #{label(pr[:state])}  #{pr[:repo]}##{pr[:number]}  #{pr[:url]}"
    end.join("\n")
  end

  def label(state)
    case state
    when :open    then "OPEN     "
    when :merged  then "merged   "
    when :closed  then "closed   "
    else               "UNREADABLE"
    end
  end

  def unreadable_note(unreadable)
    return "" if unreadable.empty?

    "     (#{unreadable.size} PR(s) above could not be read — state unknown, not established as closed)\n"
  end

  # --- the deliberate-abandonment record -----------------------------------------

  # What `--force` writes to devops.abandoned_prs: one line per PR being abandoned,
  # each carrying the url, the state it was in, and WHEN the choice was made.
  #
  # NEWLINE-FREE BY CONSTRUCTION. Task.normalize_devops_list splits every array
  # element on "\n", so an entry containing one would be silently torn into two
  # rows — a record that reads as more abandonments than happened.
  # THE URL IS THE FIRST WHITESPACE-SEPARATED FIELD, and `abandonment_recorded?`
  # depends on that. Anything prepended to it turns every receipt on the board into
  # a receipt nothing can find.
  def record(prs:, at:, by: nil)
    abandoned_prs(prs).map do |pr|
      "#{pr[:url]} #{receipt_state(pr[:state])} abandoned-at-archive #{at}#{by ? " by #{by}" : ""}".tr("\n", " ")
    end
  end

  # The word a receipt uses for a state. `:unknown` is written as `unreadable`
  # because that is what every message in this file calls it, and a receipt is prose
  # a human reads months later — "unknown" invites the reader to ask *unknown what?*
  # about the one field that is telling them the check never completed.
  def receipt_state(state)
    state == :unknown ? "unreadable" : state.to_s
  end

  # Does `recorded` carry an abandonment receipt for THIS url?
  #
  # ANCHORED ON THE WHOLE URL, NEVER A SUBSTRING. The first cut of this predicate
  # lived in bin/task as `recorded.any? { |entry| entry.include?(ref[:url]) }`, and
  # a shorter PR url is a PREFIX of a longer one: a receipt written for
  # .../pull/245 answers TRUE for .../pull/24. That fails in the UNSAFE direction —
  # a real orphan reads as "abandoned on purpose", its `decide:` remediation line is
  # suppressed, and it sorts to the bottom of `bin/task orphan-prs`. The alarm goes
  # quiet about live work, which is the exact harm this guard shipped to close.
  #
  # Comparing the first FIELD rather than matching a pattern means there is nothing
  # to escape, and a bare-url entry — a receipt written by hand — still matches,
  # because a bare url is its own first field.
  def abandonment_recorded?(recorded, url)
    target = url.to_s.strip
    return false if target.empty?

    Array(recorded).any? { |entry| entry.to_s.split(/\s+/).first == target }
  end

  # Merge the record onto whatever the task already carries, never replacing it: a
  # task can be archived, revived, and archived again, and the earlier decision is
  # still the reason an earlier PR was dropped.
  def merged_record(existing, entries)
    (Array(existing).map(&:to_s) + Array(entries)).map(&:strip).reject(&:empty?).uniq
  end
end
