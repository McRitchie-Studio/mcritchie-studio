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
  #
  # BOUNDED. Every answer (PR, branch lookup, compare) is cached on the instance,
  # and the FIRST failed read trips a breaker: every later read raises Unreadable
  # without asking GitHub, so a rate limit or outage costs one timeout per sweep,
  # not one per call. A 404 or 422 on a PR read is the exception: it is an answer
  # about THAT PR (deleted, transferred, wrong number), so it is cached per url as
  # NoSuchPr and never trips the shared breaker. Only transport errors, 5xx,
  # 401/403 and rate limits do. Tasks share one instance per process (.shared) for
  # SHARED_TTL, so a sweep over N tasks asks each question once and a tripped
  # breaker heals within the TTL.
  class TaskDerivation
    class Unreadable < StandardError; end
    # A per-PR answer (404/422): unreadable for that PR only. Still an Unreadable,
    # so every caller falls back to its stamp exactly as before.
    class NoSuchPr < Unreadable; end

    # A PR read answering one of these names that PR, not GitHub's health.
    PER_PR_STATUSES = [404, 422].freeze

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

    SHARED_TTL = 60.seconds
    SHARED_LOCK = Mutex.new

    # The per-process derivation every Task reads by default, rebuilt after
    # SHARED_TTL so its caches and breaker never outlive a sweep by much.
    def self.shared
      SHARED_LOCK.synchronize do
        if @shared.nil? || @shared_at.nil? || Time.current - @shared_at > SHARED_TTL
          @shared = new
          @shared_at = Time.current
        end
        @shared
      end
    end

    def self.reset_shared!
      SHARED_LOCK.synchronize { @shared = @shared_at = nil }
    end

    # The PR urls a free-form abandoned-PR note names, normalized, so a match is
    # exact: an abandoned #159 never excludes #15.
    def self.pr_urls_in(text)
      text.to_s.scan(%r{https://github\.com/[^/\s]+/[^/\s]+/pull/\d+}).map { |url| normalize_url(url) }
    end

    def self.normalize_url(url)
      url.to_s.strip.sub(%r{/+\z}, "")
    end

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
      @branch_prs = {}
      @compares = {}
      @missing = {}
      @failure = nil
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
      pulls = @branch_prs[[nwo, branch.to_s]] ||=
        read { client.get("/repos/#{nwo}/pulls", params: { head: "#{owner}:#{branch}", state: "all", per_page: 30 }) }
      gone = Array(exclude).flat_map { |note| self.class.pr_urls_in(note) }
      candidates = Array(pulls).select { |pr| pr.is_a?(Hash) && pr["html_url"].present? }
      candidates = candidates.reject { |pr| gone.include?(self.class.normalize_url(pr["html_url"])) }
      best = candidates.max_by do |pr|
        [pr["merged_at"].present? ? 2 : (pr["state"] == "open" ? 1 : 0), pr["number"].to_i]
      end
      best && best["html_url"]
    end

    # Every soul who authored a commit on the PR, or opened it. Raises Unreadable.
    def authors(pr_url)
      nwo, number = parse!(pr_url)
      commits = read_pr(pr_url) { client.paginate("/repos/#{nwo}/pulls/#{number}/commits") }
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
        read_pr(pr_url) { client.get("/repos/#{nwo}/pulls/#{number}") }
      end
    end

    # A branch the repo does not carry (a two-rung repo has no `release`) answers
    # 404, which is "does not contain", not a failed read. Anything else that is
    # not a 2xx is unreadable.
    def contains?(nwo, rung, sha)
      key = [nwo, rung, sha]
      return @compares[key] if @compares.key?(key)

      @compares[key] = begin
        tripped!
        CONTAINED_STATUSES.include?(client.get("/repos/#{nwo}/compare/#{rung}...#{sha}")["status"].to_s)
      rescue Github::Client::HttpError => e
        raise e unless e.message.start_with?("GitHub API HTTP 404")

        false
      end
    rescue Unreadable
      raise
    rescue StandardError => e
      fail!("compare #{nwo} #{rung}...#{sha}: #{e.class}: #{e.message}")
    end

    def read
      tripped!
      yield
    rescue Unreadable
      raise
    rescue StandardError => e
      fail!("#{e.class}: #{e.message}")
    end

    # #read for a single PR: a 404/422 is cached as that url's NoSuchPr and leaves
    # the breaker alone; every other failure trips it as #read does.
    def read_pr(pr_url)
      raise @missing[pr_url] if @missing.key?(pr_url)

      read do
        yield
      rescue Github::Client::HttpError => e
        raise e unless per_pr_status?(e)

        raise(@missing[pr_url] = NoSuchPr.new("no such PR #{pr_url}: #{e.message}"))
      end
    end

    def per_pr_status?(error)
      status = error.message[/\AGitHub API HTTP (\d{3})/, 1].to_i
      PER_PR_STATUSES.include?(status)
    end

    # The breaker: once one read has failed, later reads fail fast.
    def tripped!
      raise Unreadable, "skipped: an earlier GitHub read failed (#{@failure})" if @failure
    end

    def fail!(message)
      @failure = message
      raise Unreadable, message
    end
  end
end
