# frozen_string_literal: true

# AssetBrowser's test-env source: a YAML listing with S3's delimiter and
# continuation semantics, so no test or e2e run calls a live bucket.
module AssetBrowser
  class FixtureSource
    def initialize(path)
      @entries = YAML.safe_load_file(path, permitted_classes: [ Time ]).map do |row|
        Entry.new(key: row["key"], size: row["size"], last_modified: row["last_modified"])
      end.sort_by(&:key)
    end

    def label = "fixture"

    def list(prefix:, max:, delimiter:, token: nil)
      rows = []
      @entries.each do |entry|
        next unless entry.key.start_with?(prefix.to_s)

        rest = entry.key.delete_prefix(prefix.to_s)
        folder = delimiter && rest.include?(delimiter) ? "#{prefix}#{rest.split(delimiter).first}#{delimiter}" : nil
        rows << (folder || entry) unless folder && rows.include?(folder)
      end
      offset = token.to_i
      slice = rows[offset, max] || []
      Page.new(folders: slice.grep(String), files: slice.grep(Entry),
               next_token: offset + max < rows.size ? (offset + max).to_s : nil)
    end

    def head(key:) = @entries.find { |entry| entry.key == key }

    def signed_url(key:, expires_in:)
      "https://fixture.invalid/#{key}?X-Amz-Expires=#{expires_in}&X-Amz-Signature=fixture"
    end
  end
end
