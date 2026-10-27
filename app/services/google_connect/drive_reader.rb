module GoogleConnect
  # Reads a connected account's Drive: names and types only, no file content.
  #
  # TWO KINDS OF CONNECTION (GoogleConnection, /tasks/drive-files-you-pick):
  #
  #   drive.file      the files the person picked (GoogleDrivePick), and no
  #                   other: #picked reads each by id. #files answers this.
  #   drive.readonly  a row connected before the change (GoogleConnection#legacy?):
  #                   the whole Drive, newest first, as it always read. #files
  #                   answers #newest for it until it reconnects.
  #
  # Every call is a GET (Reader): nothing here can change a file.
  class DriveReader < Reader
    LABEL = "Google Drive".freeze
    FILES_URL = "https://www.googleapis.com/drive/v3/files".freeze
    FIELDS = "id,name,mimeType,modifiedTime,webViewLink".freeze

    Item = Struct.new(:id, :name, :mime_type, :modified_at, :url, keyword_init: true)

    # What an agent may read of this connection: the picked files for a
    # drive.file row, the newest of the whole Drive for a legacy one, and
    # nothing for a row without Drive.
    def files(limit: 5)
      if @connection.drive_picked? then picked(limit:)
      elsif @connection.legacy?(:drive) then newest(limit:)
      else []
      end
    end

    # The whole Drive, newest first. Legacy (drive.readonly) rows only: under
    # drive.file Google itself answers just the app's files, and #picked is the read.
    def newest(limit: 5)
      query = { pageSize: limit, orderBy: "modifiedTime desc", q: "trashed = false", fields: "files(#{FIELDS})" }
      Array(get_json("#{FILES_URL}?#{URI.encode_www_form(query)}")["files"]).map { item(_1) }
    end

    # The picked files, newest pick first, each read by its id. A file Google
    # no longer hands over (unshared, deleted, access withdrawn) answers 404
    # and is left out, not raised: the others still read.
    def picked(limit: 5)
      @connection.drive_picks.newest_first.limit(limit).filter_map { |pick| file(pick.file_id, missing: nil) }
    end

    # One file's metadata by id. `missing` is what a 404 answers (raise by default).
    def file(id, missing: :raise)
      raise ArgumentError, "not a Drive file id" unless id.to_s.match?(/\A[\w-]+\z/)

      url = "#{FILES_URL}/#{id}?#{URI.encode_www_form(fields: FIELDS, supportsAllDrives: true)}"
      status, body = get(url, token)
      return missing if status == 404 && missing != :raise

      item(status == 200 ? JSON.parse(body.to_s) : get_json(url))
    end

    private

    def item(file)
      Item.new(id: file["id"], name: file["name"].presence || "(untitled)", mime_type: file["mimeType"], url: file["webViewLink"],
               modified_at: file["modifiedTime"].present? ? Time.iso8601(file["modifiedTime"]) : nil)
    end
  end
end
