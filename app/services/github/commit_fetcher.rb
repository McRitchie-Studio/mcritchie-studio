module Github
  class CommitFetcher
    SEARCH_ACCEPT_HEADER = {
      "Accept" => "application/vnd.github+json"
    }.freeze
    DEFAULT_REPO_SCOPE_MIN_OBSERVATIONS = 25
    DEFAULT_SEARCH_RANGE_DAYS = 91

    def initialize(client: Github::Client.new, logger: Rails.logger,
      repo_scope_min_observations: ENV.fetch("GITHUB_REPO_SCOPE_MIN_OBSERVATIONS", DEFAULT_REPO_SCOPE_MIN_OBSERVATIONS).to_i,
      search_range_days: ENV.fetch("GITHUB_SEARCH_RANGE_DAYS", DEFAULT_SEARCH_RANGE_DAYS).to_i)
      @client = client
      @logger = logger
      @repo_scope_min_observations = repo_scope_min_observations
      @search_range_days = [search_range_days, 1].max
    end

    def fetch_for_builder(builder:, start_date:, end_date:, after_segment: nil)
      start_date = parse_date(start_date)
      end_date = parse_date(end_date)
      repos = builder.active_repos.to_a

      if repos.any?
        repo_result = fetch_repo_scoped(builder, repos, start_date, end_date, after_segment: after_segment)
        return repo_result unless repo_scope_sparse?(builder, start_date, end_date)

        search_result = fetch_search_scoped(builder, start_date, end_date, after_segment: after_segment)
        {
          strategy: "repo_scoped_with_search_supplement",
          stored: repo_result[:stored].to_i + search_result[:stored].to_i,
          repo_scoped: repo_result,
          search: search_result
        }
      else
        fetch_search_scoped(builder, start_date, end_date, after_segment: after_segment)
      end
    end

    private

    def fetch_repo_scoped(builder, repos, start_date, end_date, after_segment:)
      stored = 0

      repos.each do |tracked_repo|
        payloads = []
        %i[author committer].each do |role|
          payloads.concat(
            @client.paginate(
              "/repos/#{tracked_repo.repo_full_name}/commits",
              params: {
                role => builder.github_login,
                since: start_time(start_date),
                until: end_time(end_date),
                per_page: 100
              }
            )
          )
        end

        payloads.uniq { |payload| payload["sha"] }.each do |payload|
          stored += 1 if upsert_observation(
            builder: builder,
            payload: payload,
            repo_full_name: tracked_repo.repo_full_name,
            source_strategy: "repo_scoped"
          )
        end

        after_segment&.call(start_date, end_date)
      end

      @logger&.info("GitHub commit fetch repo_scoped login=#{builder.github_login} stored=#{stored}")
      { strategy: "repo_scoped", stored: stored }
    end

    def fetch_search_scoped(builder, start_date, end_date, after_segment:)
      stored = 0

      search_date_ranges(start_date, end_date).each do |range_start, range_end|
        %i[author committer].each do |role|
          payloads = @client.paginate(
            "/search/commits",
            params: {
              q: search_query(builder.github_login, role, range_start, range_end),
              per_page: 100
            },
            headers: SEARCH_ACCEPT_HEADER
          )

          payloads.uniq { |payload| payload["sha"] }.each do |payload|
            stored += 1 if upsert_observation(
              builder: builder,
              payload: payload,
              repo_full_name: payload.dig("repository", "full_name"),
              source_strategy: "search"
            )
          end
        end

        after_segment&.call(range_start, range_end)
      end

      @logger&.info("GitHub commit fetch search login=#{builder.github_login} stored=#{stored}")
      { strategy: "search", stored: stored, search_range_days: @search_range_days }
    end

    def upsert_observation(builder:, payload:, repo_full_name:, source_strategy:)
      repo_full_name = repo_full_name.to_s
      sha = payload["sha"].to_s
      return false if repo_full_name.blank? || sha.blank?

      observation = GithubCommitObservation.find_or_initialize_by(
        repo_full_name: repo_full_name,
        sha: sha,
        github_login: builder.github_login
      )
      observation.assign_attributes(
        author_login: payload.dig("author", "login"),
        committer_login: payload.dig("committer", "login"),
        authored_at: parse_time(payload.dig("commit", "author", "date")),
        committed_at: parse_time(payload.dig("commit", "committer", "date")),
        message: payload.dig("commit", "message"),
        html_url: payload["html_url"],
        is_merge: Github::CommitClassifier.merge?(payload),
        is_bot: Github::CommitClassifier.bot?(payload),
        source_strategy: observation.new_record? ? source_strategy : preferred_source_strategy(observation.source_strategy, source_strategy),
        raw_payload: payload
      )
      observation.save!
      true
    end

    def repo_scope_sparse?(builder, start_date, end_date)
      return false if @repo_scope_min_observations <= 0

      observation_count = GithubCommitObservation.for_login(builder.github_login)
        .where(
          "(committed_at >= ? AND committed_at <= ?) OR " \
          "(committed_at IS NULL AND authored_at >= ? AND authored_at <= ?)",
          start_date.beginning_of_day, end_date.end_of_day,
          start_date.beginning_of_day, end_date.end_of_day
        )
        .count

      sparse = observation_count < @repo_scope_min_observations
      if sparse
        @logger&.info(
          "GitHub commit fetch repo scope sparse login=#{builder.github_login} " \
          "observations=#{observation_count} threshold=#{@repo_scope_min_observations}; supplementing with search"
        )
      end
      sparse
    end

    def preferred_source_strategy(existing_strategy, new_strategy)
      return "repo_scoped" if existing_strategy == "repo_scoped"

      new_strategy
    end

    def search_query(github_login, role, range_start, range_end)
      date_qualifier = role == :author ? "author-date" : "committer-date"
      "#{role}:#{github_login} #{date_qualifier}:#{range_start.iso8601}..#{range_end.iso8601} merge:false is:public"
    end

    def search_date_ranges(start_date, end_date)
      ranges = []
      current = start_date
      while current <= end_date
        range_end = [current + @search_range_days - 1, end_date].min
        ranges << [current, range_end]
        current = range_end + 1
      end
      ranges
    end

    def start_time(date)
      date.beginning_of_day.iso8601
    end

    def end_time(date)
      date.end_of_day.iso8601
    end

    def parse_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    end
  end
end
