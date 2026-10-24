module AgentMessages
  # The files a person attaches to a CTO web chat message (.agents/epics/chat-media-design.md,
  # step 1: images and PDFs). One place holds the rules, so the upload endpoint
  # (CtoChatAttachmentsController#create) and the message store (WebIngest) can
  # never disagree about them:
  #
  #   TYPES       what a file may be, read from its BYTES (Marcel), never its
  #               name or the browser's word: PNG, JPEG, WebP, GIF, HEIC/HEIF
  #               and PDF. HEIC is stored as sent; the dispatcher converts it
  #               to JPEG before the model sees it (AgentMailbox::Media)
  #   MAX_BYTES   images 20 MB, a PDF 32 MB
  #   MAX_FILES   10 files a message
  #   UPLOAD_LIMIT uploads per user per UPLOAD_WINDOW, across every app, on top
  #               of the message rate limit (WebIngest::RATE_LIMIT)
  #
  # WHERE THEY LIVE: R2, on the PRIVATE Active Storage service SERVICE
  # (`chat_private`: its own bucket pair with no public domain,
  # StorageBackend.chat_private_service), never the hub's bucket, whose public
  # custom domain serves any key to anyone. Keys are
  # `apps/<app slug>/chat/u<user id>-<token>/<file>`.
  #
  # OFF UNTIL THAT BUCKET EXISTS: enabled? is false while the private service has
  # no keys (StorageBackend.chat_private_configured?). Then the composer shows no
  # Attach, an upload and a message with files are refused (ATTACHMENTS_OFF),
  # and text chat is unchanged. The key is written here on
  # the server, so the prefix is also the proof of whose upload a blob is: a
  # message may attach only blobs under ITS app's and ITS sender's prefix.
  #
  # PRIVATE: the browser never gets a blob URL. The form carries a SIGNED TOKEN
  # (purpose TOKEN_PURPOSE, TOKEN_TTL), which Active Storage's own public
  # routes do not accept, and a sent file is shown only through
  # CtoChatAttachmentsController#show, which checks the viewer is the thread's
  # owner or an admin and redirects to an R2 URL that expires in URL_TTL. The
  # dispatcher reads the same kind of URL from the holder-only context bundle.
  #
  # A FILE IS DATA. Nothing here, on the dispatcher or in the model's prompt
  # reads a file as an instruction; nothing acts without the owner's `go`.
  module Attachments
    TYPES = {
      "image/png" => "image", "image/jpeg" => "image", "image/webp" => "image", "image/gif" => "image",
      "image/heic" => "image", "image/heif" => "image", "application/pdf" => "pdf"
    }.freeze
    MAX_BYTES = { "image" => 20.megabytes, "pdf" => 32.megabytes }.freeze
    MAX_FILES = 10
    UPLOAD_LIMIT = 60
    UPLOAD_WINDOW = 1.hour
    URL_TTL = 5.minutes
    # The dispatcher fetches right after it claims; this covers a slow queue.
    WORKER_URL_TTL = 15.minutes
    TOKEN_PURPOSE = :cto_chat_attachment
    TOKEN_TTL = 1.day
    # What a browser draws as a picture; HEIC shows as a file chip.
    PREVIEWABLE = %w[image/png image/jpeg image/webp image/gif].freeze
    ACCEPT = ".png,.jpg,.jpeg,.webp,.gif,.heic,.heif,.pdf,#{TYPES.keys.join(',')}".freeze
    LABELS = { "image" => "an image", "pdf" => "a PDF" }.freeze

    SERVICE = :chat_private
    OFF_MESSAGE = "Attaching files is not switched on for this chat yet.".freeze

    Refused = WebIngest::Refused

    # nil: read the configuration (the test suite's Disk service is always on);
    # true/false: a test pins it.
    mattr_accessor :enabled_override, default: nil

    module_function

    def enabled?
      return enabled_override unless enabled_override.nil?

      Rails.env.test? || StorageBackend.chat_private_configured?
    end

    def refuse_when_off!
      raise Refused.new(OFF_MESSAGE, code: "ATTACHMENTS_OFF") unless enabled?
    end

    def kind(content_type) = TYPES[content_type.to_s]
    def previewable?(blob) = PREVIEWABLE.include?(blob.content_type.to_s)

    def key_prefix(app_slug, user_id) = "apps/#{app_slug}/chat/u#{Integer(user_id)}-"

    def key_for(app_slug, user_id, filename)
      name = ActiveStorage::Filename.new(filename.to_s).sanitized.gsub(/[^A-Za-z0-9._-]/, "_").gsub(/\.{2,}/, ".")
      name = name[-100..] if name.length > 100
      name = "file" if name.blank? || name.match?(/\A[._-]+\z/)
      "#{key_prefix(app_slug, user_id)}#{SecureRandom.base36(24)}/#{name}"
    end

    # The checks on one file's TYPE and SIZE; raises Refused naming the file.
    def check!(content_type:, byte_size:, filename:)
      kind = kind(content_type)
      raise Refused.new("#{filename} is not an image or a PDF. Attach PNG, JPG, WebP, GIF, HEIC or PDF.", code: "ATTACHMENT_TYPE") unless kind

      max = MAX_BYTES.fetch(kind)
      return kind if byte_size.to_i.between?(1, max)

      raise Refused.new("#{filename} is empty.", code: "ATTACHMENT_EMPTY") unless byte_size.to_i.positive?

      raise Refused.new("#{filename} is over #{max / 1.megabyte} MB, the limit for #{LABELS.fetch(kind)}.", code: "ATTACHMENT_TOO_BIG")
    end

    # Stores one upload for `user` in `app_slug`'s chat and returns the blob.
    # The type is read from the bytes; the size from the file. Raises Refused.
    # Marked analyzed, so Active Storage never runs its image analyzer on an
    # untrusted upload on the hub: only the dispatcher's ImageMagick decodes it.
    def upload!(io:, filename:, app_slug:, user:, now: Time.current)
      refuse_when_off!
      raise Refused.new("Attach a file first.", code: "ATTACHMENT_MISSING") if io.nil?
      if uploads_since(user.id, now - UPLOAD_WINDOW) >= UPLOAD_LIMIT
        raise Refused.new("That is a lot of files in an hour. Try again later.", code: "ATTACHMENT_RATE_LIMITED")
      end

      filename = filename.to_s.presence || "file"
      content_type = sniff(io)
      check!(content_type: content_type, byte_size: io.size, filename: filename)
      ActiveStorage::Blob.create_and_upload!(io: io, filename: filename, content_type: content_type, identify: false,
                                             service_name: SERVICE,
                                             key: key_for(app_slug, user.id, filename),
                                             metadata: { "analyzed" => true, "identified" => true,
                                                         "cto_chat" => { "app" => app_slug, "user_id" => user.id } })
    end

    # HEIF's ISO-BMFF brands (an iPhone writes `heic`, an editor `heix` or
    # `mif1`), which Marcel reads as video/quicktime.
    HEIF_BRANDS = %w[heic heix hevc hevx heim heis].freeze

    # The type the BYTES say, never the name: HEIC/HEIF by the ftyp box's
    # brands, everything else by Marcel. Leaves `io` rewound.
    def sniff(io)
      head = io.read(64).to_s.b
      io.rewind
      if head[4, 4] == "ftyp"
        major = head[8, 4]
        brands = head[16, [ head[0, 4].unpack1("N").to_i - 16, 0 ].max].to_s.scan(/.{4}/m)
        return "image/heic" if HEIF_BRANDS.include?(major)
        return "image/heif" if %w[mif1 msf1].include?(major) && (brands & HEIF_BRANDS).any?
      end
      Marcel::MimeType.for(io).tap { io.rewind }
    end

    # How many chat files `user_id` uploaded since `since`, on any app, read from
    # the key prefix this module writes.
    def uploads_since(user_id, since)
      ActiveStorage::Blob.where("key LIKE ?", "apps/%/chat/u#{Integer(user_id)}-%").where("created_at > ?", since).count
    end

    # The token the composer carries for one uploaded blob.
    def token_for(blob) = blob.signed_id(purpose: TOKEN_PURPOSE, expires_in: TOKEN_TTL)

    # The blobs `tokens` name, for a message from `user` in `app_slug`'s chat,
    # checked: at most MAX_FILES, each a live token for a blob under this app's
    # and this user's prefix, not yet on any message, and each within TYPES and
    # MAX_BYTES. Raises Refused on the first that is not.
    def resolve!(tokens, app_slug:, user:)
      tokens = Array(tokens).map(&:to_s).reject(&:blank?).uniq
      return [] if tokens.empty?

      refuse_when_off!
      raise Refused.new("Attach at most #{MAX_FILES} files to one message.", code: "ATTACHMENT_TOO_MANY") if tokens.size > MAX_FILES

      prefix = key_prefix(app_slug, user.id)
      tokens.map do |token|
        blob = ActiveStorage::Blob.find_signed(token, purpose: TOKEN_PURPOSE)
        unless blob&.key.to_s.start_with?(prefix) && blob.service_name.to_s == SERVICE.to_s
          raise Refused.new("A file you attached has expired. Attach it again.", code: "ATTACHMENT_INVALID")
        end
        raise Refused.new("#{blob.filename} is already on a message.", code: "ATTACHMENT_USED") if blob.attachments.exists?

        check!(content_type: blob.content_type, byte_size: blob.byte_size, filename: blob.filename.to_s)
        blob
      end
    end

    # The files a refused send carried, to show again as ready chips: [[token,
    # blob]] for each token that still names an unsent blob of this user's in
    # this app (the first MAX_FILES + 1, so a too-many refusal still shows why).
    # Lenient on purpose: it only redraws; WebIngest checks every rule at send.
    def held(tokens, app_slug:, user:)
      return [] unless enabled?

      prefix = key_prefix(app_slug, user.id)
      Array(tokens).map(&:to_s).reject(&:blank?).uniq.first(MAX_FILES + 1).filter_map do |token|
        blob = ActiveStorage::Blob.find_signed(token, purpose: TOKEN_PURPOSE)
        [ token, blob ] if blob&.key.to_s.start_with?(prefix) && !blob.attachments.exists?
      end
    end

    # Whether `user` may see `attachment`: it is on a web chat message in
    # `app_slug`'s chat, and the user wrote it or is an admin.
    def visible_to?(attachment, app_slug:, user:)
      message = attachment&.record
      return false unless message.is_a?(AgentMessage) && attachment.name == "attachments"
      return false unless message.channel == "web" && message.channel_ref == app_slug

      user.admin? || message.author_ref == user.id.to_s
    end

    # The path that shows one sent file (no URL helpers: the turn partial also
    # renders in broadcasts, outside a request).
    def path(message, attachment, download: false)
      "/applications/#{message.channel_ref}/chat/attachments/#{attachment.id}#{'?download=1' if download}"
    end

    # The files as the holder's context bundle gives them to the dispatcher: what
    # each is, and a URL that expires in WORKER_URL_TTL. Needs
    # ActiveStorage::Current.url_options on a Disk service (tests, a keyless desk).
    def for_worker(message)
      message.attachments.map do |attachment|
        blob = attachment.blob
        { "id" => attachment.id, "filename" => blob.filename.to_s, "content_type" => blob.content_type,
          "byte_size" => blob.byte_size, "kind" => kind(blob.content_type),
          "url" => blob.url(expires_in: WORKER_URL_TTL, disposition: :attachment) }
      end
    end
  end
end
