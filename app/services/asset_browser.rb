# frozen_string_literal: true

# The /assets browser: reads the hub's object store as a folder tree over key
# prefixes. It reads through Studio::S3 (S3 or R2, per STUDIO_S3_BACKEND), one
# page at a time, and never lists the whole bucket into memory.
#
# Search is bounded: it scans at most SEARCH_SCAN_LIMIT keys under the current
# folder and says so when it stops short.
module AssetBrowser
  PAGE_SIZE = 200
  SEARCH_SCAN_LIMIT = 5_000
  SEARCH_MATCH_LIMIT = 200
  SIGNED_URL_TTL = 15.minutes.to_i

  IMAGE_EXTENSIONS = %w[jpg jpeg png gif webp avif svg].freeze
  VIDEO_EXTENSIONS = %w[mp4 m4v mov webm].freeze

  class Unavailable < StandardError; end

  Entry = Data.define(:key, :size, :last_modified, :content_type) do
    def initialize(key:, size:, last_modified:, content_type: nil)
      super
    end

    def name = key.split("/").last.to_s
    def extension = File.extname(name).delete_prefix(".").downcase

    # The stored type when the store sent one, else read from the name.
    def mime = content_type.presence || Marcel::MimeType.for(name: name)

    def kind
      return :image if IMAGE_EXTENSIONS.include?(extension)
      return :video if VIDEO_EXTENSIONS.include?(extension)

      :other
    end

    def folder = key.delete_suffix(name)
  end

  Page = Data.define(:folders, :files, :next_token)
  SearchResult = Data.define(:matches, :scanned, :complete, :scan_limit, :truncated_matches)
  Preview = Data.define(:entry, :url)

  class << self
    attr_writer :source

    # The live store unless an initializer set another (the test env does).
    def source
      @source || S3Source.new
    end

    def list(prefix:, token: nil, page_size: PAGE_SIZE, source: self.source)
      source.list(prefix: prefix, token: token, max: page_size, delimiter: "/")
    end

    def search(query:, prefix:, scan_limit: SEARCH_SCAN_LIMIT, page_size: 1_000, source: self.source)
      needle = query.to_s.downcase
      matches = []
      scanned = 0
      token = nil
      loop do
        page = source.list(prefix: prefix, token: token, max: [ page_size, scan_limit - scanned ].min, delimiter: nil)
        page.files.each { |entry| matches << entry if entry.name.downcase.include?(needle) }
        scanned += page.files.size
        token = page.next_token
        break if token.nil? || scanned >= scan_limit
      end
      SearchResult.new(matches: matches.first(SEARCH_MATCH_LIMIT), scanned: scanned, complete: token.nil?,
                       scan_limit: scan_limit, truncated_matches: matches.size > SEARCH_MATCH_LIMIT)
    end

    def preview(key, source: self.source)
      entry = source.head(key: key)
      entry && Preview.new(entry: entry, url: source.signed_url(key: key, expires_in: SIGNED_URL_TTL))
    end

    # "" for the root, else "a/b/". Anything carrying ".." reads as the root.
    def normalize_prefix(value)
      parts = value.to_s.split("/").reject(&:blank?)
      return "" if parts.empty? || parts.include?("..")

      "#{parts.join('/')}/"
    end

    def breadcrumbs(prefix)
      parts = prefix.to_s.split("/").reject(&:blank?)
      parts.each_index.map { |i| [ parts[i], "#{parts[0..i].join('/')}/" ] }
    end
  end
end
