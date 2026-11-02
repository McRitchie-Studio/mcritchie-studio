require "net/http"
require "tempfile"

module AgentMessages
  # Fetches the files on one Slack event and stores them where every chat file
  # lives (AgentMessages::Attachments: the private bucket, images and PDFs, the
  # type read from the bytes). The dispatcher reads them from the context bundle
  # as it reads a web chat's files. Needs the bot scope files:read.
  #
  # THE TOKEN. SLACK_BOT_TOKEN goes only to HOST, over https. A file's URL comes
  # from the event, so any other host is refused, and a redirect is never
  # followed (without files:read Slack answers with a redirect to its sign-in
  # page; that is a reason, not a place to go).
  #
  # ONCE. A file's key is built from the message and the file's ids, so a retried
  # event reuses the stored blob, and all of a fan-out's rows share one.
  #
  # NEVER FATAL. A file that cannot be stored is SKIPPED with a reason a person
  # can read. The message is stored either way. A fault on our side (a missing
  # scope, a storage failure) also lands on the error log, so it reaches triage
  # and not only the one thread.
  class SlackFiles
    HOST = "files.slack.com".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30
    # Slack's own marks for a file with no bytes to fetch.
    GONE_MODES = %w[tombstone hidden_by_limit].freeze
    NO_ACCESS = "Slack would not hand it over; the app may be missing files:read".freeze

    class Unreadable < StandardError; end
    class NoAccess < Unreadable; end

    Result = Struct.new(:blobs, :skipped, keyword_init: true)

    def initialize(token: ENV[Media::Slack::TOKEN_ENV], fetcher: nil, logger: Rails.logger)
      @token = token.to_s
      @fetcher = fetcher || method(:http_get)
      @logger = logger
    end

    def call(event, team_id:)
      files = Array(event["files"]).select { |file| file.is_a?(Hash) }
      blobs = []
      skipped = files.drop(Attachments::MAX_FILES).map { |file| skip(file, "over the limit of #{Attachments::MAX_FILES} files") }
      files.first(Attachments::MAX_FILES).each do |file|
        blobs << store(file, event, team_id)
      rescue NoAccess => e
        report(e, file)
        skipped << skip(file, e.message)
      rescue Unreadable, Attachments::Refused => e
        skipped << skip(file, e.message)
      rescue StandardError => e
        report(e, file)
        skipped << skip(file, "could not be stored")
      end
      Result.new(blobs: blobs.uniq, skipped: skipped)
    end

    private

    def store(file, event, team_id)
      raise Unreadable, "file storage is not switched on" unless Attachments.enabled?
      raise Unreadable, "Slack no longer has it" if GONE_MODES.include?(file["mode"])

      name = name_of(file)
      Attachments.check!(content_type: file["mimetype"], byte_size: file["size"], filename: name)
      key = key_for(file, event, team_id, name)
      ActiveStorage::Blob.find_by(key: key) || fetched(file) do |io|
        Attachments.store!(io: io, filename: name, key: key,
                           origin: { "slack" => { "team" => team_id.to_s, "channel" => event["channel"].to_s,
                                                  "ts" => event["ts"].to_s, "file" => file["id"].to_s } })
      end
    end

    def fetched(file)
      Tempfile.create("slack-file", binmode: true) do |io|
        @fetcher.call(allowed_uri(file), io, @token)
        io.rewind
        yield io
      end
    end

    # The file's download URL, only when the bot token may go there.
    def allowed_uri(file)
      uri = URI.parse((file["url_private_download"].presence || file["url_private"]).to_s)
      raise Unreadable, "it has a link the app will not follow" unless uri.is_a?(URI::HTTPS) && uri.host == HOST

      uri
    rescue URI::InvalidURIError
      raise Unreadable, "it has a link the app will not follow"
    end

    def key_for(file, event, team_id, name)
      ids = [ team_id, event["channel"], event["ts"], file["id"] ].map { |id| id.to_s.gsub(/[^A-Za-z0-9.]/, "_") }
      "slack/#{ids.join('/')}/#{Attachments.safe_name(name)}"
    end

    def name_of(file) = (file["name"].presence || file["title"].presence || "file").to_s[0, 200]

    def report(error, file)
      @logger.warn("[agent-messages] Slack file #{file['id']} not stored: #{error.class}")
      ErrorLog.capture!(error)&.update(target_name: "Slack file #{file['id'].to_s[0, 40]}")
    rescue StandardError
      nil
    end

    def skip(file, reason) = { "filename" => name_of(file), "reason" => reason.to_s[0, 200] }

    # Streams the file into `io`, stopping past the largest size a file may be.
    def http_get(uri, io, token)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request) do |response|
          raise NoAccess, NO_ACCESS unless response.is_a?(Net::HTTPSuccess)

          response.read_body do |chunk|
            io.write(chunk)
            raise Unreadable, "it is larger than Slack said" if io.size > Attachments::MAX_BYTES.values.max
          end
        end
      end
    rescue *Media::Http::NEVER_SENT, *Media::Http::MAYBE_SENT
      raise Unreadable, "could not be downloaded"
    end
  end
end
