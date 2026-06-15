module Github
  class CommitFetcher
    SEARCH_ACCEPT_HEADER = {
      "Accept" => "application/vnd.github+json"
    }.freeze

    def initialize(client: Github::Client.new, logger: Rails.logger)
      @client = client
      @logger = logger
    end

    def fetch_for_builder(builder:, start_date:, end_date:)
      start_date = parse_date(start_date)
      end_date = parse_date(end_date)
      repos = builder.active_repos.to_a

      if repos.any?
        fetch_repo_scoped(builder, repos, start_date, end_date)
      else
        fetch_search_scoped(builder, start_date, end_date)
      end
    end

    private

    def fetch_repo_scoped(builder, repos, start_date, end_date)
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
      end

      @logger&.info("GitHub commit fetch repo_scoped login=#{builder.github_login} stored=#{stored}")
      { strategy: "repo_scoped", stored: stored }
    end

    def fetch_search_scoped(builder, start_date, end_date)
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
      end

      @logger&.info("GitHub commit fetch search login=#{builder.github_login} stored=#{stored}")
      { strategy: "search", stored: stored }
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
        source_strategy: source_strategy,
        raw_payload: payload
      )
      observation.save!
      true
    end

    def search_query(github_login, role, range_start, range_end)
      date_qualifier = role == :author ? "author-date" : "committer-date"
      "#{role}:#{github_login} #{date_qualifier}:#{range_start.iso8601}..#{range_end.iso8601} merge:false is:public"
    end

    def search_date_ranges(start_date, end_date)
      ranges = []
      current = start_date
      while current <= end_date
        range_end = [current + 6, end_date].min
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
