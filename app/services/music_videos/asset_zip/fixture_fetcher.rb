# frozen_string_literal: true

module MusicVideos
  module AssetZip
    # The test env's fetcher: a few synthetic bytes per entry, read in two
    # chunks, so no test or e2e run touches a bucket or a sheet host. A source
    # containing "missing" fails, as an absent object does.
    class FixtureFetcher
      def each_chunk(entry)
        raise FetchFailed, "not in storage" if entry.source.to_s.include?("missing")

        body = "synthetic #{entry.kind} #{entry.source}\n"
        yield body[0, 10]
        yield body[10..]
      end
    end
  end
end
