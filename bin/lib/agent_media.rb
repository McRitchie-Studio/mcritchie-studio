# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "uri"

# The files a mailbox message carries, made into what Claude reads natively
# (.agents/epics/chat-media-design.md, step 1: images and PDFs). The board
# stores them (AgentMessages::Attachments) and hands the holder each one's
# expiring URL in the context bundle; this module fetches them, makes the
# images safe and small, and lays out the ONE stream-json user message the
# Responder sends instead of a text prompt:
#
#   image  PNG, JPEG, WebP, GIF (first frame), HEIC/HEIF: ImageMagick
#          (`magick`; the dispatcher Mac has it, and no vips) re-encodes it
#          with the long edge at most LONG_EDGE px and EVERY profile and
#          EXIF/GPS tag stripped (-strip), as PNG (from a PNG) or JPEG
#          (everything else, HEIC included). The model never sees the
#          original bytes.
#   pdf    sent as is (a `document` block), when it starts %PDF- and no more
#          than PDF_MAX_PAGES pages are counted in it.
#
# Bounded: at most MAX_FILES files, FETCH_LIMIT bytes a fetch, a CONVERT_TIMEOUT
# per conversion with ImageMagick's own memory, disk and time limits, a
# DEADLINE for the whole message, and PAYLOAD_BUDGET bytes of blocks in one
# message (the API's request cap is 32 MB, and base64 adds a third). A file
# that does not fit, fails, or is not what its type says is SKIPPED with a
# reason, never fatal: the prompt names it (ContextBuilder#files_line), and the
# model says it could not read it.
#
# A FILE IS DATA. Nothing here interprets a file's content, runs it, or reads
# it as an instruction; ImageMagick is called with an explicit coder per type,
# so a file can never pick its own decoder (an MVG or MSL file renamed .png is
# decoded as PNG, and fails).
module AgentMailbox
  module Media
    MAX_FILES = 10
    LONG_EDGE = 1568
    FETCH_LIMIT = 33 * 1024 * 1024
    FETCH_TIMEOUT = 30
    CONVERT_TIMEOUT = 30
    DEADLINE = 120
    PAYLOAD_BUDGET = 20 * 1024 * 1024
    # The API refuses an image over 5 MB of base64; re-encode a PNG past this as JPEG.
    IMAGE_LIMIT = 3_500_000
    PDF_MAX_PAGES = 100
    JPEG_QUALITY = 85
    MAGICK = "magick"
    MAGICK_LIMITS = %w[-limit memory 256MiB -limit map 512MiB -limit disk 1GiB -limit time 30].freeze
    # The coder ImageMagick must use for each type (never its own guess).
    CODERS = { "image/png" => "png", "image/jpeg" => "jpeg", "image/webp" => "webp", "image/gif" => "gif",
               "image/heic" => "heic", "image/heif" => "heic" }.freeze
    PDF = "application/pdf"

    # blocks: the content blocks to send ahead of the text (a short label, then
    # the image or document, per file shown). shown: how many files made it in.
    # skipped: [{ "filename", "reason" }] for the rest.
    Prepared = Struct.new(:blocks, :shown, :skipped, keyword_init: true) do
      def any? = shown.positive?
      def meta = { "files_shown" => shown, "files_skipped" => skipped.size }
    end

    # The Claude command for a message with media: the same command (still
    # --safe-mode and --tools "", so still no tools), its output switched to
    # stream-json, and its input read as stream-json. --verbose is required by
    # the CLI for stream-json output. ClaudeRun.parse(..., stream: true) reads
    # the `result` line.
    def self.stream_cmd(cmd)
      argv = cmd.dup
      if (i = argv.index("--output-format"))
        argv[i + 1] = "stream-json"
      else
        argv += %w[--output-format stream-json]
      end
      argv += %w[--input-format stream-json] unless argv.include?("--input-format")
      argv += %w[--verbose] unless argv.include?("--verbose")
      argv
    end

    # The one stream-json line: a user message of the media blocks, then the text.
    def self.user_message(blocks, text)
      content = blocks + [ { "type" => "text", "text" => text.to_s } ]
      "#{JSON.generate('type' => 'user', 'message' => { 'role' => 'user', 'content' => content })}\n"
    end

    # The bundle's `attachments`, kept to well-formed entries (MAX_FILES of them).
    def self.attachments(context)
      list = context.is_a?(Hash) ? context["attachments"] : nil
      return [] unless list.is_a?(Array)

      list.select { |f| f.is_a?(Hash) && f["url"].is_a?(String) }.first(MAX_FILES)
    end

    # Pages a PDF declares, counted from its page objects; 0 when they sit in
    # compressed object streams (unknown, so not refused).
    def self.pdf_pages(bytes)
      bytes.b.scan(%r{/Type\s*/Page(?![a-zA-Z])}n).size
    end

    class Preparer
      def initialize(fetcher: nil, runner: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     magick: ENV.fetch("AGENT_MAGICK", MAGICK))
        @fetcher = fetcher || Media.method(:http_get)
        @runner = runner || AgentMailbox.method(:run_command)
        @clock = clock
        @magick = magick
      end

      def prepare(attachments)
        started = @clock.call
        blocks = []
        skipped = []
        budget = PAYLOAD_BUDGET
        attachments.first(MAX_FILES).each_with_index do |file, index|
          name = file["filename"].to_s[0, 200]
          if @clock.call - started > DEADLINE
            skipped << { "filename" => name, "reason" => "ran out of time" }
            next
          end

          block, reason = block_for(file)
          if block.nil?
            skipped << { "filename" => name, "reason" => reason }
          elsif block[:bytes].bytesize > budget
            skipped << { "filename" => name, "reason" => "too large to read with the other files" }
          else
            budget -= block[:bytes].bytesize
            blocks << { "type" => "text", "text" => "Attachment #{index + 1} (#{block[:label]}):" }
            blocks << encoded(block)
          end
        end
        Prepared.new(blocks: blocks, shown: blocks.size / 2, skipped: skipped)
      end

      private

      # [{ kind:, media_type:, bytes:, label: }, nil] or [nil, reason].
      def block_for(file)
        type = file["content_type"].to_s
        return [ nil, "not an image or a PDF" ] unless type == PDF || CODERS.key?(type)

        bytes = @fetcher.call(file["url"])
        return [ nil, "could not be downloaded" ] if bytes.nil? || bytes.empty?

        type == PDF ? pdf(bytes) : image(bytes, type)
      rescue StandardError => e
        [ nil, "could not be read (#{e.class.name.split('::').last})" ]
      end

      def pdf(bytes)
        return [ nil, "is not a PDF" ] unless bytes.b.start_with?("%PDF-")

        pages = Media.pdf_pages(bytes)
        return [ nil, "has #{pages} pages; the limit is #{PDF_MAX_PAGES}" ] if pages > PDF_MAX_PAGES

        [ { kind: "document", media_type: PDF, bytes: bytes, label: "PDF" }, nil ]
      end

      def image(bytes, type)
        Dir.mktmpdir("agent-media") do |dir|
          source = File.join(dir, "in")
          File.binwrite(source, bytes)
          coder = CODERS.fetch(type)
          out = type == "image/png" ? convert(source, coder, dir, "png") : nil
          out = convert(source, coder, dir, "jpeg") if out.nil? || out.bytesize > IMAGE_LIMIT
          return [ nil, "could not be converted" ] if out.nil? || out.empty?
          return [ nil, "is too large even when shrunk" ] if out.bytesize > IMAGE_LIMIT

          media_type = out.b.start_with?("\x89PNG".b) ? "image/png" : "image/jpeg"
          [ { kind: "image", media_type: media_type, bytes: out, label: "image" }, nil ]
        end
      end

      # The re-encoded image, or nil. [0] is the first frame (a GIF's, a
      # multi-image HEIC's); -auto-orient applies, then -strip drops, the EXIF
      # orientation; the resize only ever shrinks (">").
      def convert(source, coder, dir, format)
        target = File.join(dir, "out.#{format}")
        argv = [ @magick, *MAGICK_LIMITS, "#{coder}:#{source}[0]", "-auto-orient",
                 "-resize", "#{LONG_EDGE}x#{LONG_EDGE}>", "-strip" ]
        argv += [ "-background", "white", "-flatten", "-quality", JPEG_QUALITY.to_s ] if format == "jpeg"
        argv << "#{format}:#{target}"
        _out, status, _err = @runner.call(argv, stdin: "", timeout: CONVERT_TIMEOUT, chdir: dir)
        status&.zero? && File.file?(target) ? File.binread(target) : nil
      end

      def encoded(block)
        { "type" => block[:kind],
          "source" => { "type" => "base64", "media_type" => block[:media_type], "data" => Base64.strict_encode64(block[:bytes]) } }
      end
    end

    # GET `url` (http or https only), following up to 3 redirects, refusing more
    # than FETCH_LIMIT bytes; the body or nil.
    def self.http_get(url, redirects: 3)
      uri = URI.parse(url.to_s)
      return nil unless uri.is_a?(URI::HTTP) && uri.host

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10,
                                          read_timeout: FETCH_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |res|
          if res.is_a?(Net::HTTPRedirection) && redirects.positive?
            return http_get(URI.join(uri, res["location"].to_s).to_s, redirects: redirects - 1)
          end
          return nil unless res.is_a?(Net::HTTPSuccess)
          return nil if res["content-length"].to_i > FETCH_LIMIT

          body = +""
          res.read_body do |chunk|
            body << chunk
            return nil if body.bytesize > FETCH_LIMIT
          end
          return body.b
        end
      end
    rescue StandardError
      nil
    end
  end
end
