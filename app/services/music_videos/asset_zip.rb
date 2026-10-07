# frozen_string_literal: true

module MusicVideos
  # The alt video asset zips (recast pipeline, piece 17): everything the
  # Higgsfield hand-off needs, one folder per clip, downloaded in one go.
  #
  #   <video>_alt_<n>/README.txt                         who A, B, C... are, sheet numbering, what is missing
  #   <video>_alt_<n>/clip_03_0040-0105/source_clip.mp4  the 25 s source chunk
  #   .../prompt.txt                                     the card's prompt, byte for byte
  #   .../frames/frame_1_B_0045.jpg                      lettered reference frames, card order
  #   .../sheets/sheet_1_B_04_<person>_<look>.png        character sheets, the prompt's order
  #
  # Three parts, so the naming is tested without any I/O and the I/O without
  # any naming:
  #
  #   Manifest  every path and where its bytes come from, read off rows the
  #             page already loads (no N+1); the README text.
  #   Fetcher   the bytes of one entry, as a stream: R2 objects through
  #             Studio::S3, sheet images over https from public hosts only.
  #   Writer    walks the manifest into a ZipKit::Streamer, store-only, and
  #             turns any entry it cannot read into a README line; stops at
  #             once when the client goes away (Puma::ConnectionError), and
  #             records any other unnamed failure in ErrorLog once per zip.
  #
  # WHY STREAMED, not built by a job into R2: a full zip is about 7 x 10-40 MB
  # of MP4 plus images. Streamed, the dyno holds one network chunk at a time
  # (measured: see docs/agents/agents/pokemon/sops/digest-video.md), the first
  # byte leaves within a second (Heroku: 30 s), and bytes keep flowing while
  # R2 does (Heroku: 55 s idle). A job would need a second stored copy, a
  # poll and a cleanup, for a download one operator runs by hand.
  module AssetZip
    # One entry's bytes could not be read. The message is a short reason for
    # the README, never a credential or a signed URL.
    class FetchFailed < StandardError; end

    class << self
      attr_writer :fetcher

      # The live fetcher unless an initializer set another (the test env does).
      def fetcher
        @fetcher || Fetcher.new
      end
    end
  end
end
