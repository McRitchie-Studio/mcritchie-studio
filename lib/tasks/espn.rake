namespace :espn do
  desc "Scrape ESPN per-team depth charts and apply to DepthChart. TEAM=buf for one team. VERBOSE=1 for full match logs."
  task scrape_depth_charts: :environment do
    # THE LOUDEST FAILURE WAS THE LEAST FINDABLE. A raise out of `call` — an
    # unreadable teams index, or a MissingTeamId escaping the per-team rescue — kills
    # the task with a backtrace on stderr and leaves nothing in /admin/error_logs, so
    # the one place an operator looks a week later is empty for the one failure that
    # stopped the scrape dead. Filed and RE-RAISED: the lane must still go red, and
    # the rescue adds a row and changes no verdict.
    #
    # NO DOUBLE ROW. The per-team rescue inside the service files and then returns nil
    # rather than re-raising, and it lets MissingTeamId past WITHOUT filing, so an
    # exception that reaches here has not been recorded anywhere yet.
    # A typo is not an outage: refuse it before any request, and file nothing.
    begin
      team = Espn::ScrapeDepthCharts.normalize_team!(ENV["TEAM"])
    rescue Espn::ScrapeDepthCharts::UnknownTeam => e
      abort "espn:scrape_depth_charts: #{e.message}"
    end

    begin
      stats = Espn::ScrapeDepthCharts.new(team_abbrev: team, verbose: ENV["VERBOSE"].present?).call
    rescue StandardError => e
      Appearances::FailureLog.file(e)
      raise
    end

    applied   = stats[:teams_scraped].to_i
    failed    = stats[:teams_failed].to_i
    partial   = stats[:teams_partial].to_i
    missed    = failed + partial
    attempted = applied + missed

    # THE VERDICT LIVES HERE, NOT IN THE SERVICE. Espn::ScrapeDepthCharts
    # swallows a dead feed per team ON PURPOSE — one unreachable team must not
    # cost the other 31 their refresh, and a partial ESPN response is skipped
    # rather than allowed to overwrite a good chart. The cost of that design is
    # that `call` returns a tally and never raises, so the process exited 0 with
    # every team down. MEASURED, not read: with fetch_groups stubbed to nil for
    # all 32 teams the task printed `{:teams_failed=>32}` and exited 0, and the
    # rebuild lane's `&&` logged a green entry count through a total outage.
    #
    # Graded on the tally the service already returns, so the service keeps its
    # per-team tolerance and only the LANE gets an exit code that discriminates.
    if missed.positive?
      warn "espn:scrape_depth_charts: #{applied} of #{attempted} teams applied " \
           "(#{failed} failed, #{partial} partial)"
    end

    # A PARTIAL RUN STAYS GREEN, DELIBERATELY. One dead team is a normal ESPN
    # afternoon, and a lane that goes red on it is a lane an operator learns to
    # ignore — the same defect in another costume. It is reported on stderr
    # instead, which the rebuild lane no longer discards, so degradation is
    # legible without being fatal. Zero teams applied is the other thing: that
    # is not degradation, it is the scrape not happening.
    if applied.zero? && attempted.positive?
      verdict = "espn:scrape_depth_charts applied 0 of #{attempted} teams — the scrape did " \
                "not happen (ESPN unreachable, or its JSON shape moved). Depth charts are " \
                "unchanged; rosters snapshotted after this will be last week's."

      # THE ABORT IS FILED BEFORE IT IS TAKEN. `abort` writes the sentence to stderr
      # and raises SystemExit; bin/ecosystem-build turns that into one `log_fail` line
      # in a build log nobody keeps, and nothing durable records that the scrape did
      # not happen. Raised and immediately rescued so the row carries a real class,
      # message and backtrace — the shape Insights::DocFreshnessJob uses for its own
      # receipt.
      #
      # ONLY THIS BRANCH. A PARTIAL run is a normal ESPN afternoon and deliberately
      # stays green; the `warn` above reports it and the per-team rows the service
      # filed already carry each cause, so a row for the tally would be a second
      # spelling of facts already on file. Zero applied is the other thing: that is
      # not degradation, it is the scrape not happening.
      begin
        raise Espn::ScrapeDepthCharts::ScrapeDidNotHappen, verdict
      rescue Espn::ScrapeDepthCharts::ScrapeDidNotHappen => e
        Appearances::FailureLog.file(e)
      end

      abort verdict
    end
  end
end
