module Github
  # Derives three task facts from GitHub instead of trusting a hand-written stamp
  # (epic devops-v3, piece 4a — design doc section 2 rule 3, "the board derives,
  # it is not told"):
  #
  #   1. MERGED RUNG — which of `main`, `release` or `accepted` contains the PR's
  #      merge commit. Asked highest rung first, so a shipped PR costs one compare.
  #   2. PR URL — the PR whose head is the task branch (`pulls?head=`), for a task
  #      that never recorded one.
  #   3. AUTHORS — the soul slugs on the PR's commits (author email
  #      `<soul>@mcritchie.studio`, or a Co-Authored-By trailer at that domain)
  #      plus the PR author's login when it names a soul.
  #
  # API only, never a git checkout: the board runs on a Heroku dyno with no clone.
  # Every read is a GET. A read that fails raises Unreadable, and the CALLER (Task)
  # falls back to the stamp — an unmeasurable rung and "not merged" are different
  # answers, and collapsing them is how a guard goes quietly blind.
  class TaskDerivation
    class Unreadable < StandardError; end

    # Highest rung first: a commit on `main` is also on `release` and `accepted`,
    # so the first branch that contains it is the task's rung.
    RUNGS = %w[main release accepted].freeze

    # compare/{branch}...{sha}: `behind` means the sha is an ancestor of the
    # branch, `identical` means it is the branch tip. Both mean "contains".
    CONTAINED_STATUSES = %w[behind identical].freeze

    # Agent commits carry `<soul>@mcritchie.studio` as their author email; the
    # operator's own address and the GitHub App bot are not souls.
    SOUL_EMAIL = /\A([a-z0-9][a-z0-9-]*)@mcritchie\.studio\z/i
    CO_AUTHOR_TRAILER = /^co-authored-by:.*<([^>]+)>\s*$/i
    PR_URL = %r{\Ahttps://github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)}

    def self.parse_pr_url(url)
      match = url.to_s.strip.match(PR_URL)
      match ? [match[1], match[2].to_i] : nil
    end

    # The soul an email names, or nil. Canonicalised (a retired `alex` lands on
    # `xan`) and roster-checked, so a typo'd local part names nobody.
    def self.soul_from_email(email)
      local = email.to_s.strip[SOUL_EMAIL, 1]
      return nil unless local

      soul = Task.canonical_soul(local.downcase)
      Task.soul?(soul) ? soul : nil
    end

    def self.souls_from_message(message)
      message.to_s.scan(CO_AUTHOR_TRAILER).flatten.filter_map { |email| soul_from_email(email) }
    end

    def initialize(client: nil, owner: Ci::ReviewGate::DEFAULT_OWNER)
      @client = client
      @owner = owner
      @pulls = {}
    end

    # "main" / "release" / "accepted", or nil when the PR is not merged (or its
    # merge commit sits on no rung yet). Raises Unreadable on a failed read.
    def merged_rung(pr_url)
      nwo, = parse!(pr_url)
      pull = pull(pr_url)
      sha = pull["merge_commit_sha"].to_s
      return nil unless pull["merged"] && !sha.empty?

      RUNGS.find { |rung| contains?(nwo, rung, sha) }
    end

    # The html_url of the PR whose head is `branch` in `repo`, or nil. Prefers a
    # merged PR, then an open one, then the newest; skips any url in `exclude`
    # (the task's abandoned PRs).
    def pr_url_for_branch(repo, branch, exclude: [])
      return nil if repo.to_s.empty? || branch.to_s.empty?

      nwo = repo.to_s.include?("/") ? repo.to_s : "#{@owner}/#{repo}"
      owner = nwo.split("/").first
      pulls = read { client.get("/repos/#{nwo}/pulls", params: { head: "#{owner}:#{branch}", state: "all", per_page: 30 }) }
      candidates = Array(pulls).select { |pr| pr.is_a?(Hash) && pr["html_url"].present? }
      candidates = candidates.reject { |pr| exclude.any? { |gone| gone.to_s.include?(pr["html_url"]) } }
      best = candidates.max_by do |pr|
        [pr["merged_at"].present? ? 2 : (pr["state"] == "open" ? 1 : 0), pr["number"].to_i]
      end
      best && best["html_url"]
    end

    # Every soul who authored a commit on the PR, or opened it. Raises Unreadable.
    def authors(pr_url)
      nwo, number = parse!(pr_url)
      commits = read { client.paginate("/repos/#{nwo}/pulls/#{number}/commits") }
      souls = Array(commits).flat_map do |entry|
        commit = entry.is_a?(Hash) ? (entry["commit"] || {}) : {}
        [self.class.soul_from_email(commit.dig("author", "email")),
         self.class.soul_from_email(commit.dig("committer", "email"))] +
          self.class.souls_from_message(commit["message"])
      end
      login = pull(pr_url).dig("user", "login").to_s.downcase
      souls << Task.canonical_soul(login) if Task.soul?(login)
      souls.compact.uniq
    end

    private

    def client
      @client ||= Github::Client.new
    end

    def parse!(pr_url)
      self.class.parse_pr_url(pr_url) || raise(Unreadable, "not a GitHub PR url: #{pr_url.inspect}")
    end

    def pull(pr_url)
      @pulls[pr_url] ||= begin
        nwo, number = parse!(pr_url)
        read { client.get("/repos/#{nwo}/pulls/#{number}") }
      end
    end

    # A branch the repo does not carry (a two-rung repo has no `release`) answers
    # 404, which is "does not contain", not a failed read. Anything else that is
    # not a 2xx is unreadable.
    def contains?(nwo, rung, sha)
      body = client.get("/repos/#{nwo}/compare/#{rung}...#{sha}")
      CONTAINED_STATUSES.include?(body["status"].to_s)
    rescue Github::Client::HttpError => e
      return false if e.message.start_with?("GitHub API HTTP 404")

      raise Unreadable, "compare #{nwo} #{rung}...#{sha}: #{e.message}"
    rescue StandardError => e
      raise Unreadable, "compare #{nwo} #{rung}...#{sha}: #{e.class}: #{e.message}"
    end

    def read
      yield
    rescue Unreadable
      raise
    rescue StandardError => e
      raise Unreadable, "#{e.class}: #{e.message}"
    end
  end
end
