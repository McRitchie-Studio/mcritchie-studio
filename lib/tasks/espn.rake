namespace :espn do
  desc "Scrape ESPN per-team depth charts and apply to DepthChart. TEAM=buf for one team. VERBOSE=1 for full match logs."
  task scrape_depth_charts: :environment do
    stats = Espn::ScrapeDepthCharts.new(team_abbrev: ENV["TEAM"], verbose: ENV["VERBOSE"].present?).call

    applied   = stats[:teams_scraped].to_i
    failed    = stats[:teams_failed].to_i
    partial   = stats[:teams_partial].to_i
    unknown   = stats[:teams_skipped].to_i
    missed    = failed + partial + unknown
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
           "(#{failed} failed, #{partial} partial, #{unknown} unknown abbrev)"
    end

    # A PARTIAL RUN STAYS GREEN, DELIBERATELY. One dead team is a normal ESPN
    # afternoon, and a lane that goes red on it is a lane an operator learns to
    # ignore — the same defect in another costume. It is reported on stderr
    # instead, which the rebuild lane no longer discards, so degradation is
    # legible without being fatal. Zero teams applied is the other thing: that
    # is not degradation, it is the scrape not happening.
    if applied.zero? && attempted.positive?
      abort "espn:scrape_depth_charts applied 0 of #{attempted} teams — the scrape did " \
            "not happen (ESPN unreachable, or its JSON shape moved). Depth charts are " \
            "unchanged; rosters snapshotted after this will be last week's."
    end
  end
end
