module Github
  class Query
    SEARCH_ACCEPT_HEADER = {
      "Accept" => "application/vnd.github+json"
    }.freeze

    class << self
      def commit_search(...)
        new.commit_search(...)
      end

      def commits_for_login(...)
        new.commits_for_login(...)
      end

      def commits_for_email(...)
        new.commits_for_email(...)
      end
    end

    def initialize(client: Github::Client.new)
      @client = client
    end

    def commit_search(q:, per_page: 5, page: nil)
      params = { q: q, per_page: per_page }
      params[:page] = page if page.present?

      @client.get_response(
        "/search/commits",
        params: params,
        headers: SEARCH_ACCEPT_HEADER
      )
    end

    def commits_for_login(login, start_date:, end_date:, role: :author, per_page: 5, page: nil)
      role = normalize_role(role)

      commit_search(
        q: commit_query(
          identity_qualifier: role.to_s,
          identity: login,
          date_qualifier: date_qualifier_for(role),
          start_date: start_date,
          end_date: end_date
        ),
        per_page: per_page,
        page: page
      )
    end

    def commits_for_email(email, start_date:, end_date:, role: :author, per_page: 5, page: nil)
      role = normalize_role(role)
      identity_qualifier = role == :author ? "author-email" : "committer-email"

      commit_search(
        q: commit_query(
          identity_qualifier: identity_qualifier,
          identity: email,
          date_qualifier: date_qualifier_for(role),
          start_date: start_date,
          end_date: end_date
        ),
        per_page: per_page,
        page: page
      )
    end

    private

    def commit_query(identity_qualifier:, identity:, date_qualifier:, start_date:, end_date:)
      "#{identity_qualifier}:#{identity} " \
        "#{date_qualifier}:#{parse_date(start_date).iso8601}..#{parse_date(end_date).iso8601} " \
        "merge:false is:public"
    end

    def date_qualifier_for(role)
      role == :author ? "author-date" : "committer-date"
    end

    def normalize_role(role)
      normalized = role.to_s.to_sym
      return normalized if %i[author committer].include?(normalized)

      raise ArgumentError, "role must be :author or :committer"
    end

    def parse_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end
  end
end
