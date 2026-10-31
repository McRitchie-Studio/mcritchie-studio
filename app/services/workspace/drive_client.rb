require "stringio"

module Workspace
  # Thin wrapper over the Drive v3 calls the knowledge layer needs. No business
  # logic: no filing, no snapshotting, no ownership decisions. Those belong to
  # the tasks that consume this.
  #
  # WRITE SURFACE, stated plainly because it matters more than the read surface:
  # #files_create, #files_copy, #files_update, #files_trash, #permissions_create
  # and #permissions_create_domain are the only methods here that change anything, and under this credential's scopes
  # they can only reach files the app itself created (see Credentials::SCOPES on
  # why `drive.file` means that under domain-wide delegation). The ownership CHECK that decides whether to
  # copy before editing is a caller's job and lands with the binding task; this
  # class deliberately does not pretend to make that decision.
  class DriveClient
    include ApiRetry

    # What a file listing needs to make a filing decision without a second
    # round-trip: identity, type, revision, and — load-bearing — the owner, so
    # a caller can tell OUR file from a third party's before it writes.
    # `version` is the index's freshness key: Google raises it on EVERY server-side
    # change, and it is the only change signal that covers native Google Docs —
    # md5Checksum and headRevisionId are present for binary files only.
    FILE_FIELDS = "id,name,mimeType,modifiedTime,version,size,md5Checksum,headRevisionId," \
                  "owners(emailAddress),capabilities(canEdit),parents,webViewLink,trashed," \
                  "shortcutDetails(targetId,targetMimeType)".freeze

    LIST_FIELDS = "nextPageToken,files(#{FILE_FIELDS})".freeze

    def initialize(subject: nil, credentials: Credentials, sleeper: method(:sleep), service: nil)
      @subject = subject
      @credentials = credentials
      @sleeper = sleeper
      @service = service
    end

    def service
      @service ||= begin
        require "google/apis/drive_v3"

        ::Google::Apis::DriveV3::DriveService.new.tap do |svc|
          svc.authorization = @credentials.authorizer_for(@subject)
        end
      end
    end

    # One page. `query` is Drive's own q syntax; it is required rather than
    # defaulted, because a defaulted listing walks the whole of a Drive.
    def files_list(query:, cursor: nil, limit: 100, fields: LIST_FIELDS)
      raise Error, "refusing to list Drive without a query" if query.to_s.strip.empty?

      with_retries("files.list", sleeper: @sleeper) do
        service.list_files(q: query, page_token: cursor, page_size: limit, fields: fields,
                           supports_all_drives: true, include_items_from_all_drives: true)
      end
    end

    def files_get(id, fields: FILE_FIELDS)
      with_retries("files.get", sleeper: @sleeper) do
        service.get_file(id, fields: fields, supports_all_drives: true)
      end
    end

    # Binary content of a NON-Google file.
    def files_download(id)
      with_retries("files.get(media)", sleeper: @sleeper) do
        buffer = StringIO.new
        service.get_file(id, download_dest: buffer, supports_all_drives: true)
        buffer.string
      end
    end

    # A Google-native doc (Doc, Sheet, Slide) has no bytes of its own — it must
    # be exported to a concrete type. Returns the exported bytes.
    def files_export(id, mime_type:)
      with_retries("files.export", sleeper: @sleeper) do
        buffer = StringIO.new
        service.export_file(id, mime_type, download_dest: buffer)
        buffer.string
      end
    end

    # `parents` is not optional in practice: a copy with no parent lands in the
    # subject's My Drive root, and a copy into a folder we do not own is refused
    # by Drive. Callers pass a folder the subject owns. Like a create, a copy that
    # may have landed is not retried: a second copy is a duplicate by name.
    def files_copy(id, name: nil, parents: nil)
      metadata = ::Google::Apis::DriveV3::File.new
      metadata.name = name if name
      metadata.parents = Array(parents) if parents

      with_retries("files.copy", sleeper: @sleeper, idempotent: false) do
        service.copy_file(id, metadata, fields: FILE_FIELDS, supports_all_drives: true)
      end
    end

    # A new file or folder in `parents`. `mime_type` is what Drive should STORE:
    # pass a Google type (document, spreadsheet, presentation) with a `body` of
    # another `content_type` and Drive converts on upload. A folder has no body.
    def files_create(name:, parents:, mime_type: nil, body: nil, content_type: nil)
      metadata = ::Google::Apis::DriveV3::File.new(name: name, parents: Array(parents))
      metadata.mime_type = mime_type if mime_type

      with_retries("files.create", sleeper: @sleeper, idempotent: false) do
        service.create_file(metadata, upload_source: (StringIO.new(body) if body), content_type: content_type,
                                      fields: FILE_FIELDS, supports_all_drives: true)
      end
    end

    def files_update(id, name: nil, body: nil, content_type: nil)
      metadata = ::Google::Apis::DriveV3::File.new
      metadata.name = name if name

      with_retries("files.update", sleeper: @sleeper) do
        service.update_file(id, metadata, upload_source: (StringIO.new(body) if body),
                                          content_type: content_type, fields: FILE_FIELDS,
                                          supports_all_drives: true)
      end
    end

    # Moves a file to the trash, where Drive keeps it 30 days: the reversible
    # delete. Trashing twice is harmless, so it retries like any update.
    def files_trash(id)
      with_retries("files.update(trash)", sleeper: @sleeper) do
        service.update_file(id, ::Google::Apis::DriveV3::File.new(trashed: true),
                            fields: "id,trashed", supports_all_drives: true)
      end
    end

    # Who can reach this file, and how. The ownership question this answers is
    # the one guardrail the write path hangs on.
    def permissions_list(id)
      with_retries("permissions.list", sleeper: @sleeper) do
        service.list_permissions(id, fields: "permissions(id,type,role,emailAddress,domain)",
                                     supports_all_drives: true)
      end
    end

    # Shares a file with one person, without Google's notification email.
    def permissions_create(id, email:, role: "writer")
      permission = ::Google::Apis::DriveV3::Permission.new(type: "user", role: role, email_address: email)
      with_retries("permissions.create", sleeper: @sleeper, idempotent: false) do
        service.create_permission(id, permission, send_notification_email: false, fields: "id,type,role,emailAddress",
                                                  supports_all_drives: true)
      end
    end

    # Shares a file with everyone signed in to one Workspace domain, findable in
    # their Drive search (allow_file_discovery), so a team reaches the kit
    # without being invited one by one.
    def permissions_create_domain(id, domain:, role: "writer")
      permission = ::Google::Apis::DriveV3::Permission.new(type: "domain", role: role, domain: domain, allow_file_discovery: true)
      with_retries("permissions.create", sleeper: @sleeper, idempotent: false) do
        service.create_permission(id, permission, fields: "id,type,role,domain", supports_all_drives: true)
      end
    end

    # Walks every page and concatenates `files`. Google signals the last page by
    # OMITTING next_page_token; an empty string would loop forever, so .presence
    # guards both shapes.
    def paged(query:, limit: 100, fields: LIST_FIELDS)
      out = []
      cursor = nil
      loop do
        page = files_list(query: query, cursor: cursor, limit: limit, fields: fields)
        out.concat(Array(page.files))
        cursor = page.next_page_token.presence
        break if cursor.nil?
      end
      out
    end
  end
end
