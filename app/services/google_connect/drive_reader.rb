module GoogleConnect
  # Lists the most recently modified files in a connected account's Drive,
  # with the drive ability's drive.readonly grant: names and types only, no
  # file content.
  class DriveReader < Reader
    LABEL = "Google Drive".freeze
    FILES_URL = "https://www.googleapis.com/drive/v3/files".freeze

    Item = Struct.new(:id, :name, :mime_type, :modified_at, keyword_init: true)

    def newest(limit: 5)
      query = { pageSize: limit, orderBy: "modifiedTime desc", q: "trashed = false", fields: "files(id,name,mimeType,modifiedTime)" }
      Array(get_json("#{FILES_URL}?#{URI.encode_www_form(query)}")["files"]).map do |file|
        Item.new(id: file["id"], name: file["name"].presence || "(untitled)", mime_type: file["mimeType"],
                 modified_at: file["modifiedTime"].present? ? Time.iso8601(file["modifiedTime"]) : nil)
      end
    end
  end
end
