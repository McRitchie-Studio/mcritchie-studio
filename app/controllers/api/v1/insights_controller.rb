module Api
  module V1
    class InsightsController < BaseController
      # The learning loop's feed-forward READ path. The Insight Bank
      # (ActionGrade.banked) is the curated set of lessons past sessions kept;
      # this endpoint serves the top-N (newest curation first) as a compact list so
      # a SessionStart hook (bin/session-insights) can inject them into a fresh
      # agent's context — turning the loop from write-only into feed-forward.
      #
      # Bearer-gated exactly like the other /api/v1 sinks (the SessionStart hook
      # mints the same agent token). Read-only.

      # GET /api/v1/insights?limit=N
      #
      # Returns { data: [ {slug, disposition, long_form?, grader, task_slug?}, … ] },
      # newest curation first, capped (ActionGrade clamps limit to 1..MAX_FEED_LIMIT).
      # `limit` is optional; omitted → ActionGrade::DEFAULT_FEED_LIMIT.
      def index
        feed = ActionGrade.insight_feed(limit: feed_limit).map(&:to_insight)
        render_data(feed, meta: { count: feed.size })
      end

      private

      # The requested feed size, or nil to take the model default. The model clamps
      # the range, so a garbage value degrades to the default/cap rather than erroring.
      def feed_limit
        raw = params[:limit]
        raw.present? ? raw : ActionGrade::DEFAULT_FEED_LIMIT
      end
    end
  end
end
