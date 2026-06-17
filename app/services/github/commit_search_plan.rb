module Github
  class CommitSearchPlan
    SAFE_SEARCH_RESULT_LIMIT = 900
    PROBE_PER_PAGE = 1
    FETCH_PER_PAGE = 100
    ROLES = %i[author committer].freeze
    IDENTITY_TYPES = %i[login email].freeze
    GRANULARITY_ORDER = %i[year quarter month week].freeze

    Window = Struct.new(:start_date, :end_date, :granularity, keyword_init: true) do
      def to_range
        start_date..end_date
      end
    end

    QuerySpec = Struct.new(:identity_type, :identity, :role, :window, keyword_init: true) do
      def q
        "#{identity_qualifier}:#{identity} " \
          "#{date_qualifier}:#{window.start_date.iso8601}..#{window.end_date.iso8601} " \
          "merge:false is:public"
      end

      def probe_params
        { q: q, per_page: Github::CommitSearchPlan::PROBE_PER_PAGE }
      end

      def fetch_params
        { q: q, per_page: Github::CommitSearchPlan::FETCH_PER_PAGE }
      end

      private

      def identity_qualifier
        case identity_type
        when :login then role.to_s
        when :email then role == :author ? "author-email" : "committer-email"
        end
      end

      def date_qualifier
        role == :author ? "author-date" : "committer-date"
      end
    end

    def initialize(login:, emails: [], start_date:, end_date:, roles: ROLES)
      @login = login.to_s.strip
      @emails = Array(emails).map { |email| email.to_s.strip }.reject(&:blank?).uniq
      @start_date = parse_date(start_date)
      @end_date = parse_date(end_date)
      @roles = Array(roles).map { |role| normalize_role(role) }.uniq
    end

    def query_specs
      identities.flat_map do |identity_type, identity|
        @roles.flat_map do |role|
          initial_windows.map do |window|
            QuerySpec.new(
              identity_type: identity_type,
              identity: identity,
              role: role,
              window: window
            )
          end
        end
      end
    end

    def initial_windows
      @initial_windows ||= calendar_year_windows
    end

    def safe_to_fetch?(total_count)
      total_count.to_i <= SAFE_SEARCH_RESULT_LIMIT
    end

    def next_windows(window)
      case window.granularity
      when :year
        quarter_windows(window.start_date, window.end_date)
      when :quarter
        month_windows(window.start_date, window.end_date)
      when :month
        seven_day_windows(window.start_date, window.end_date)
      else
        [window]
      end
    end

    private

    def identities
      identities = []
      identities << [:login, @login] if @login.present?
      identities.concat(@emails.map { |email| [:email, email] })
      identities
    end

    def calendar_year_windows
      years = (@start_date.year..@end_date.year)
      years.map do |year|
        bounded_window(Date.new(year, 1, 1), Date.new(year, 12, 31), :year)
      end.compact
    end

    def quarter_windows(start_date, end_date)
      quarter_starts = [1, 4, 7, 10].map { |month| Date.new(start_date.year, month, 1) }
      if start_date.year != end_date.year
        quarter_starts = (start_date.year..end_date.year).flat_map do |year|
          [1, 4, 7, 10].map { |month| Date.new(year, month, 1) }
        end
      end

      quarter_starts.filter_map do |quarter_start|
        bounded_window(quarter_start, quarter_start.next_month(3) - 1.day, :quarter, start_date, end_date)
      end
    end

    def month_windows(start_date, end_date)
      current = Date.new(start_date.year, start_date.month, 1)
      windows = []
      while current <= end_date
        windows << bounded_window(current, current.next_month - 1.day, :month, start_date, end_date)
        current = current.next_month
      end
      windows.compact
    end

    def seven_day_windows(start_date, end_date)
      windows = []
      current = start_date
      while current <= end_date
        window_end = [current + 6.days, end_date].min
        windows << Window.new(start_date: current, end_date: window_end, granularity: :week)
        current = window_end + 1.day
      end
      windows
    end

    def bounded_window(candidate_start, candidate_end, granularity, lower_bound = @start_date, upper_bound = @end_date)
      start_date = [candidate_start, lower_bound].max
      end_date = [candidate_end, upper_bound].min
      return nil if start_date > end_date

      Window.new(start_date: start_date, end_date: end_date, granularity: granularity)
    end

    def normalize_role(role)
      normalized = role.to_s.to_sym
      return normalized if ROLES.include?(normalized)

      raise ArgumentError, "role must be :author or :committer"
    end

    def parse_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end
  end
end
