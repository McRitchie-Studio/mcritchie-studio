require "cgi"
require "net/http"
require "uri"

module Github
  class PaulMillrActiveUsersImporter
    DEFAULT_URL = "https://gist.githubusercontent.com/paulmillr/2657075/raw/a31455729440672467ada20ac10452d74a871e54/active.md".freeze
    DEFAULT_CATEGORY = "historic_prolific_github".freeze
    ROW_PATTERN = %r{
      <tr><th\ scope="row">\#(?<rank>\d+)</th>
      <td><a\ href="https://github.com/(?<login>[^"]+)">[^<]+</a>(?:\ \((?<name>.*?)\))?</td>
      <td>(?<contributions>\d+)</td>
      <td>(?<language>.*?)</td>
      <td>(?<location>.*?)</td>
    }mx

    User = Struct.new(:rank, :github_login, :name, :contributions, :language, :location, keyword_init: true)

    def initialize(http_get: nil, logger: Rails.logger)
      @http_get = http_get || method(:http_get)
      @logger = logger
    end

    def import!(url: DEFAULT_URL, cohort: "control_builder", active: true, max: nil)
      users = users(url: url)
      users = users.first(max.to_i) if max.to_i.positive?
      result = { source_url: url, seen: users.size, created: 0, updated: 0, existing_preserved: 0 }

      users.each do |user|
        builder = TrackedGithubBuilder.find_or_initialize_by(github_login: user.github_login)
        if builder.new_record?
          builder.assign_attributes(
            display_name: display_name(user),
            cohort: cohort,
            category: DEFAULT_CATEGORY,
            notes: notes_for(user, url),
            active: active
          )
          result[:created] += 1
        else
          preserve_existing_builder(builder, user, url, active)
          result[:existing_preserved] += 1
        end

        builder.save!
        result[:updated] += 1
      end

      @logger&.info("Imported Paul Miller active GitHub users #{result.inspect}")
      result
    end

    def users(url: DEFAULT_URL)
      parse(@http_get.call(url))
    end

    def parse(markdown)
      normalized_markdown(markdown).to_enum(:scan, ROW_PATTERN).map do
        match = Regexp.last_match
        User.new(
          rank: match[:rank].to_i,
          github_login: clean(match[:login]).downcase,
          name: clean(match[:name]),
          contributions: match[:contributions].to_i,
          language: clean(match[:language]),
          location: clean(match[:location])
        )
      end
    end

    private

    def normalized_markdown(markdown)
      markdown.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    end

    def preserve_existing_builder(builder, user, url, active)
      builder.active = true if active
      builder.category = DEFAULT_CATEGORY if builder.category.blank?
      builder.notes = notes_for(user, url) if builder.notes.blank?
    end

    def display_name(user)
      label = user.name.presence || user.github_login
      "Paul Miller active ##{user.rank}: #{label}"
    end

    def notes_for(user, url)
      details = [
        "Paul Miller historic active GitHub user list candidate.",
        "2012-2013 public contribution rank ##{user.rank}",
        "#{user.contributions} contributions"
      ]
      details << "language: #{user.language}" if user.language.present?
      details << "location: #{user.location}" if user.location.present?
      details << "source: #{url}"
      details << "Historic prolific control-candidate screen; verify current public commit activity before using in published analysis."
      details.join(". ")
    end

    def clean(value)
      CGI.unescapeHTML(value.to_s.gsub(/<[^>]+>/, "").strip)
    end

    def http_get(url)
      uri = URI(url)
      response = Net::HTTP.get_response(uri)
      unless response.is_a?(Net::HTTPSuccess)
        raise Github::Client::HttpError, "Paul Miller gist import HTTP #{response.code}: #{response.body}"
      end

      response.body
    end
  end
end
