# frozen_string_literal: true

module Ci
  # The /deployments app-ladder row: one card per three-rung repo, each carrying
  # its `accepted` / `release` / `main` rungs.
  #
  # WHAT IT IS FOR. An application's progress along the ladder is decoupled from
  # the Next Release card — work sits merged on `accepted` for hours before a
  # sweep promotes it, and between releases the Next Release card reads "none
  # active" while three repos quietly hold unshipped work. This row is that
  # in-between state, which had no surface at all.
  #
  # THE CLOCK RESETS AT THE SHIP, BY DERIVATION. Parked counts come from the
  # task board's own `merged` column, so nothing is stored and nothing can drift:
  #
  #   accepted rung  ← tasks stamped merged:"accepted"  (reviewed, awaiting sweep)
  #   release  rung  ← tasks stamped merged:"release"   (on the candidate, in QA)
  #   main     rung  ← nothing. Shipped work has ARRIVED; see PARKED_STAMP below.
  #
  # A sweep re-stamps accepted → release, and a ship re-stamps release → main — which
  # counts nothing — so the rungs empty on their own as work advances. After a
  # production ship every card falls quiet, the "clock starts over" the row exists to
  # show, with no counter to reset and nothing to get out of sync.
  #
  # ARCHIVED TASKS ARE EXCLUDED TOO, and that filter is doing real work even though
  # `main` no longer counts: a task can be archived while still stamped `accepted` or
  # `release`, and counting it would hold a rung open for work nobody is advancing.
  # test/models/ci/app_ladder_test.rb exercises exactly that shape — an archived task
  # at a COUNTED rung — because a fixture stamped `main` cannot bite this filter.
  class AppLadder
    RUNGS = %w[accepted release main].freeze

    # HOW MANY CARDS MEAN THE ROW OVERFLOWS — the first-paint seed for the row's
    # right-edge fade (tasks/_app_ladder_row).
    #
    # The row is ONE horizontally scrolling line of 20rem cards, so five of them
    # (5 × 320px + gaps = 1664px) cannot fit the board's widest container (1472px)
    # at any viewport. That makes five the count at which the fade is known to be
    # right BEFORE anything has measured — which is the whole of this constant's
    # job. The browser then measures for real on init and on every scroll or resize,
    # so a narrower window overflowing at four cards is corrected within a frame and
    # the fade disappears at the end of the scroll. The seed only has to be right at
    # first paint; it is not the rule.
    ROW_FADE_AT = 5

    # Which `merged` stamp parks a task at which rung.
    #
    # `main` is deliberately ABSENT. Work stamped `merged: "main"` has ARRIVED — it
    # shipped, nothing waits there, and the stamp is permanent until the task is
    # archived. Counting it meant a card never went quiet: the hub sat at "37 on main"
    # indefinitely, so the clock never reset even though the production ship is the
    # reset point the operator chose. Parked means WAITING, and only the two rungs
    # below main have anything waiting on them.
    #
    # A card showing "1 on accepted" moments after a ship is therefore correct and
    # must keep showing: that is real work queued for the next sweep, not residue.
    PARKED_STAMP = {
      "accepted" => Task::MERGED_ACCEPTED,
      "release" => Task::MERGED_RELEASE
    }.freeze

    Card = Struct.new(:repo, :rungs, :review_roll, :release_member, :release_in_qa, :last_shipped_at,
                      keyword_init: true) do
      def rung(branch) = rungs.find { |r| r.branch == branch }

      def needs_attention? = rungs.any?(&:needs_attention?)

      def parked_total = rungs.sum(&:parked_count)

      def parked_at(branch) = rung(branch)&.parked_count.to_i

      # IN THE ACTIVE RELEASE — this repo is one the open candidate actually moves.
      #
      # Read from Release#member_repos, the SAME set the per-repo tracker panel above
      # this row draws its lanes from. Sharing that one derivation is the point: two
      # copies of "is this repo in the release" is exactly how the tracker and the card
      # beneath it come to say different things about the same repo.
      def release_member? = !!release_member

      # The candidate has reached QA. Only used to WORD the `release` node: work
      # stamped merged:"release" sits on the candidate either way, but calling it
      # "in QA" before QA was deployed would claim a step nobody has run yet.
      def release_in_qa? = !!release_in_qa

      # HOW FAR THIS APP'S UNSHIPPED WORK HAS ADVANCED — the single derivation the
      # whole track is drawn from.
      #
      # Read the parked stamps FROM THE FAR END BACKWARD, because the question is how
      # far the frontier got, not where the newest work sits. An app routinely holds
      # work at `accepted` (merged, awaiting the sweep) AND at `release` (promoted, in
      # QA) in the same moment; the track must fill to `release` while the `accepted`
      # node still says "2 waiting" beside it. Reading forward would report the
      # frontier as `accepted` and draw the candidate as though it were never promoted.
      #
      # Nothing parked anywhere => `main`. That is the ARRIVED state, not an unknown
      # one: `main` is deliberately absent from PARKED_STAMP because shipped work has
      # LEFT the ladder (see the note there), so an empty board means every rung
      # drained. This is what makes "full track" and #at_rest? the same fact twice.
      def furthest_rung
        return "release" if parked_at("release").positive?
        return "accepted" if parked_at("accepted").positive?

        "main"
      end

      # Everything has arrived: nothing waits at either counted rung.
      def level? = furthest_rung == "main"

      # Nothing is HAPPENING on this app: no rung failing, no suite in flight.
      #
      # `:pending` counts as activity even though it is not a problem. A running suite
      # is live news — it is the one state the meter exists to show moving — and a card
      # that dimmed itself while its own CI was mid-run would hide exactly the thing the
      # operator opened the page for.
      def quiet? = !needs_attention? && rungs.none? { |r| r.state == :pending }

      # AT REST — the state after a ship, when this app holds nothing, has nothing
      # running, and is not in the next release, so it is not worth the operator's eye
      # until it is included again.
      #
      # #quiet? IS A SAFETY RULE, not a nicety. Dimming a card and sorting it last is a
      # CLAIM that nothing here needs attention, and a red rung or a suite mid-run
      # contradicts it. So either one keeps the full card and its place in the sort —
      # which is the property the existing worst-first sort guarantees, and the one
      # thing this must not take away.
      def at_rest? = level? && !release_member? && quiet?

      # The card's one-word position in the Deploy workflow. Drives the label, the
      # dimming, and the `data-position` attribute the view tests and e2e spec read.
      # Ordered by urgency, so the first true branch wins.
      #
      # THE LAST TWO BRANCHES ARE #at_rest?'s OWN TERMS, and that is load-bearing rather
      # than tidy. This method used to end `return :queued unless level?` / `:at_rest`,
      # deriving rest from level-and-not-a-member while #at_rest? ALSO demanded #quiet?.
      # The two then disagreed on a real board: studio-engine, drained and outside the
      # candidate but with its `release` suite mid-run, rendered the words "at rest" over
      # a live ticking CI meter — the card contradicting itself in the same glance, which
      # is the exact failure this row was rebuilt to stop. By the time control reaches
      # here the card is level, unclaimed and not failing, so `quiet?` is all that
      # separates the two, and reading it makes `:at_rest` ⟺ #at_rest? BY CONSTRUCTION.
      #
      # :verifying is the state that disagreement was hiding — drained, unclaimed, and
      # still being checked. It is not rest (a suite in flight is live news) and it is
      # not queued (nothing is waiting on a rung).
      def position
        return :attention if needs_attention?
        return :in_release if release_member?
        return :queued unless level?
        return :verifying unless quiet?

        :at_rest
      end

      # THE TRACK, as the view draws it: three segments, left to right, reading as ONE
      # progress bar across `accepted → release → main`.
      #
      #   progress — where the work is. :passed (it moved through here) / :here (it is
      #              sitting here now) / :unreached (it has not got this far).
      #   state    — the rung's OWN CI verdict, drawn as the glyph INSIDE the segment.
      #   filled   — reached at all, i.e. progress is not :unreached.
      #
      # COLOUR CARRIES PROGRESS, THE GLYPH CARRIES CI. That division is the whole design:
      # the badge row this replaced spent its only colour on the CI verdict, so it could
      # say "release is green" but never "release is empty", and the row could not answer
      # "where is this app in the devops process". Now the bar answers that at a glance
      # and the glyph keeps the verdict that used to own the colour.
      def track
        frontier = RUNGS.index(furthest_rung)

        RUNGS.each_with_index.filter_map do |branch, index|
          rung = rung(branch)
          next if rung.blank?

          progress = progress_for(rung, index, frontier)
          { branch: branch, rung: rung, state: rung.state, progress: progress,
            filled: progress != :unreached, parked: rung.parked_count }
        end
      end

      # ONE RUNG'S PLACE IN THE BAR.
      #
      # PARKED WORK WINS, and that is the rule the simple "fill up to the frontier"
      # reading gets wrong. An app routinely holds work at `accepted` (awaiting the
      # sweep) AND at `release` (promoted, in QA) at once. Colouring `accepted` green
      # there — because the frontier moved past it — would say "this rung is clear" over
      # two tasks that are still sitting on it. A rung holding work reads :here whether
      # or not the frontier went further.
      #
      # `main` IS ARRIVAL, NOT WAITING — and it needs no special case to be, which is
      # worth stating because the obvious defensive version has one. Nothing ever parks
      # at `main` (PARKED_STAMP omits it: shipped work has LEFT the ladder), so the
      # guard above can never fire there, and `index <= frontier` reads the drained
      # board's frontier (`main` itself) as :passed. That is what makes a fully drained
      # app three greens rather than two greens and an amber.
      #
      # `<=` rather than `<` for the same reason: the ONLY rung that can be at the
      # frontier without parked work is `main`, because the frontier is derived from the
      # parked counts. Mutation-tested — `index < frontier || RUNGS[frontier] == "main"`
      # is exactly equivalent and no test could tell them apart, so the shorter one wins.
      def progress_for(rung, index, frontier)
        return :here if rung.parked_count.positive?

        index <= frontier ? :passed : :unreached
      end

      # THE RUNG THE METER REPORTS ON — "what is this app's suite doing right now".
      #
      # A running rung always wins: a suite in flight is the live news, and it is the
      # only state the operator can act on while it is happening. Failing that, the
      # rung with the NEWEST verdict, because that is the most recent thing CI
      # actually said about this app. `accepted` is the last resort so a card with no
      # verdicts anywhere still names the rung its work would reach first.
      #
      # Deliberately ONE rung, not a meter per rung: three check-lists on one card is
      # the two-rows-saying-the-same-thing shape the CI meter already learned to
      # collapse, and the badges below carry the per-rung verdict anyway.
      # THE RELEASE RUNG WINS FOR A MEMBER, and that override is the whole of it.
      #
      # MEASURED 2026-08-25, mid-sweep: the tracker panel read studio-engine
      # "ASSEMBLING ✓✓✓" (the release rung, green) while the card six inches below it
      # read "ACCEPTED · ENGINE CI ○○✓" (amber). Both were true and the page still
      # contradicted itself, because a task merging onto `accepted` during the sweep
      # started a run there, and "a running rung always wins" handed the meter to a
      # rung the operator was not watching.
      #
      # So when this repo is IN the active release, the meter reports the rung the
      # release is about. Only when that rung HAS A VERDICT (`verdict_at`) — a member
      # whose `release` suite has not been ingested yet must fall through to the rule
      # below rather than blank the meter to "no CI checks ingested", which would trade
      # one wrong reading for a worse one.
      #
      # A NON-MEMBER KEEPS THE ORIGINAL RULE, unchanged and for its original reasons: a
      # suite in flight is the live news and the only state the operator can act on
      # while it happens; failing that the newest verdict, since that is the most recent
      # thing CI actually said; `accepted` last so a card with no verdicts anywhere
      # still names the rung its work would reach first.
      def active_rung
        release_rung = rung("release") if release_member?
        return release_rung if release_rung&.verdict_at

        rungs.find { |r| r.state == :pending } ||
          rungs.select(&:verdict_at).max_by(&:verdict_at) ||
          rung("accepted")
      end

      # The checks the meter draws, or nil when this app has nothing ingested — a
      # meter must not render a hopeful zero out of an absence.
      #
      # The cache lives HERE rather than on the rung: a rung is a frozen value object,
      # so it cannot hold one, and this read costs a query. `defined?` rather than
      # `||=` so a genuine nil is cached too — an app with no ingested checks is the
      # common case on a quiet board, and re-querying it per call is the N+1 this
      # memo exists to prevent.
      def progress
        return @progress if defined?(@progress)

        @progress = active_rung&.progress
      end

      # Where the card points. The Actions run behind the active rung, so clicking the
      # card lands on the run in progress rather than a repo home page.
      def run_url = active_rung&.run_url

      # AT REST SINKS; everything else keeps the original ordering — worst rung first,
      # then "has work waiting" ahead of idle, mirroring the board's own instinct of
      # floating what needs a human to the top.
      #
      # The at-rest flag leads the key rather than replacing it, so the two rules
      # compose instead of competing. It cannot bury a red card, because #at_rest? is
      # false whenever a rung needs attention — the sink and the safety rule are the
      # same condition read once.
      def sort_key
        [at_rest? ? 1 : 0, *(rungs.map(&:sort_key).min || [Ci::LadderRung::STATE_RANK[:green], 1])]
      end

      def gem? = Release::Repos.gem?(repo)

      # HOW LONG REVIEW TAKES on this app lately (Review::DurationRoll::Roll). Handed
      # in by .build from ONE ecosystem-wide read, never fetched per card — the N+1
      # this row already learned to avoid for parked counts and CI progress.
      #
      # NEVER NIL to a view: a repo with no measured review still gets an empty Roll,
      # so the card renders "not enough data" rather than a blank or a NaN. Only a
      # Card built by hand (a test fixture) can carry nil, and #review reads through
      # to an empty Roll for exactly that case.
      def review = review_roll || Review::DurationRoll.empty(repo)
    end

    class << self
      # EVERY three-rung repo gets a card — including one that declares no CI suite.
      #
      # This filter used to drop a suiteless repo as noise, on the argument that three
      # `not_built` rungs teach the eye nothing. That was wrong twice. A repo is on the
      # ladder whether or not it runs tests, and its rungs still move; hiding the card
      # hid the movement. Concretely: solana-studio sat `accepted` +1 ahead of
      # `release` with no task behind it, and the row could not show it because the
      # card did not exist. A card reading "not built" is a true and useful statement —
      # this repo ships without a suite — where an absent card says nothing at all.
      def reportable_repos = Release::Repos.three_rung_repos

      # Build every card. One board query for the parked counts (not one per
      # rung per repo), then each rung folds its own branch's suite runs.
      #
      # `release:` is READ ONCE here and handed down, never fetched per card — the same
      # N+1 discipline parked_index and the review rolls already follow. It defaults to
      # Release.current so every existing caller (the controller, DeploymentsBroadcaster,
      # the dev board) keeps working untouched, and a test can pin a candidate by
      # passing one — or pass `nil` for "no release open", which is a real board state
      # and must not become an implicit Release.current lookup deeper down.
      def build(repos: reportable_repos, release: Release.current)
        parked = parked_index
        # The review rolls for EVERY card in one read, exactly like parked_index above
        # — see Review::DurationRoll for why this must not become a per-card lookup.
        rolls = Review::DurationRoll.by_repo(repos: repos)
        members = release ? release.member_repos : []
        in_qa = release ? release.stage_reached?("qa_deployed") : false
        shipped = shipped_index

        repos.map do |repo|
          card_for(repo, parked, rolls[repo],
                   release_member: members.include?(repo), release_in_qa: in_qa,
                   last_shipped_at: shipped[repo])
        end.sort_by(&:sort_key)
      end

      def card_for(repo, parked = parked_index, review_roll = nil,
                   release_member: false, release_in_qa: false, last_shipped_at: nil)
        rungs = RUNGS.map do |branch|
          Ci::LadderRung.for(repo: repo, branch: branch, parked_count: parked.dig(repo, branch).to_i)
        end
        Card.new(repo: repo, rungs: rungs, review_roll: review_roll,
                 release_member: release_member, release_in_qa: release_in_qa,
                 last_shipped_at: last_shipped_at)
      end

      # WHEN EACH REPO LAST REACHED PRODUCTION => { "turf-monster" => Time }.
      #
      # The at-rest card drops its meter, so this is the one fact it keeps: a quiet card
      # that says nothing at all is indistinguishable from a broken one, and "shipped 3h
      # ago" is what turns the silence into a statement.
      #
      # THE RELEASE'S OWN `shipped_at` IS THE HONEST STAMP — the moment production
      # actually took the code — not the task's `updated_at`, which moves again on every
      # later edit to an archived record. Falls back to the release's `created_at` for
      # an old row shipped before the column was populated, matching
      # Release.last_shipped's own COALESCE so the two can never disagree.
      #
      # BOUNDED to the newest SHIPPED_SCAN releases. Unbounded, this walks every task
      # the ecosystem has ever shipped to answer a question about the last one; the
      # newest few releases hold the answer for every live repo, and a repo whose last
      # ship predates the window renders "shipped" with no time rather than a wrong one.
      SHIPPED_SCAN = 25

      def shipped_index
        releases = Release.where(state: "shipped")
                          .order(Arel.sql("COALESCE(shipped_at, created_at) DESC"))
                          .limit(SHIPPED_SCAN)
                          .pluck(:slug, Arel.sql("COALESCE(shipped_at, created_at)"))
        return {} if releases.empty?

        at_by_slug = releases.to_h
        index = {}

        # ORDERED, and not for the result — #shipped_index is order-independent by
        # construction (it keeps the MAX per repo). It is ordered so the max rule is
        # TESTABLE: unordered, the rows happened to arrive newest-last, so a mutation
        # replacing the comparison with plain assignment produced the right answer by
        # luck and no test could bite it.
        Task.where(release_slug: at_by_slug.keys)
            .order(:id)
            .pluck(:release_slug, :metadata)
            .each do |slug, metadata|
              at = at_by_slug[slug]
              next if at.blank?

              repos_for(metadata).each do |repo|
                index[repo] = at if index[repo].nil? || index[repo] < at
              end
            end

        index
      end

      # => { "turf-monster" => { "accepted" => 2 } }
      #
      # A COUNT and nothing more. It used to carry the newest `updated_at` per rung
      # so a green verdict older than that could be called stale — a rule removed on
      # 2026-08-20 because the stamp is always written after the run starts, so it
      # fired by construction. See Ci::LadderRung's note for the measurement.
      def parked_index
        index = Hash.new { |h, k| h[k] = Hash.new(0) }

        Task.where.not(stage: "archived")
            .where(merged: PARKED_STAMP.values)
            .pluck(:merged, :metadata)
            .each do |merged, metadata|
              branch = PARKED_STAMP.key(merged)
              next if branch.blank?

              repos_for(metadata).each { |repo| index[repo][branch] += 1 }
            end

        index
      end

      # A task can name several repos, and it parks on the rung in EVERY repo it
      # names — a multi-repo task is not "in" one of them.
      def repos_for(metadata)
        devops = metadata.is_a?(Hash) ? (metadata["devops"] || {}) : {}
        list = devops["repositories"]
        list = [list] if list.is_a?(String)
        Array(list).map { |r| r.to_s.strip }.reject(&:empty?).uniq
      end
    end
  end
end
