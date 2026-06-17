module Github
  module CommitCacheKey
    DEFAULT = "public_commit_search_v2"

    def self.current
      ENV.fetch("GITHUB_COMMIT_CACHE_KEY", DEFAULT).presence || DEFAULT
    end
  end
end
