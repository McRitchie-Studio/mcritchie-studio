# frozen_string_literal: true

module Books
  # One entity's books folder in its Drive, over Workspace::DriveClient:
  #
  #   <drive_root>/
  #     Inbox/               Alex McRitchie drops statement PDFs here
  #     Statements/<year>/   the hub's filed copy of each statement it read
  #     Closes/<YYYY-MM>/    each month's Sheet and its PDF
  #
  # Every folder is found by name under its parent, or created. Under the
  # drive.file scope the hub can write only into folders it created itself, so
  # the tree must be made by `bin/books setup`, never by hand: a hand-made
  # folder of the same name would be found and then refuse every write.
  #
  # Inbox files stay where Alex put them: the hub cannot move a file it did not
  # create. Intake records each one's id, so a second run skips it.
  #
  # WHOSE DRIVE. The tree lives in the drive_subject's Drive (the domain's team@
  # workspace subject, the only address the hub may act as there) and its root is
  # shared with `share_with` as a writer, so Alex McRitchie sees it in his own
  # Drive and can drop statements into the Inbox. A subject that is not an ACTIVE
  # workspace_account is refused here, by name, before any Google call.
  class Drive
    Error = Class.new(StandardError)

    FOLDER_MIME = "application/vnd.google-apps.folder"
    SHEET_MIME = "application/vnd.google-apps.spreadsheet"
    PDF_MIME = "application/pdf"
    XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    attr_reader :entity

    def initialize(entity, client: nil)
      @entity = entity
      @client = client
      @folders = {}
    end

    def client
      @client ||= begin
        unless WorkspaceAccount.impersonatable?(entity.drive_subject)
          raise Error, "#{entity.key}'s drive_subject #{entity.drive_subject} is not an ACTIVE workspace_account; " \
                       "the hub reaches Drive only as a domain's registered subject (team@<domain>). Fix config/books.yml"
        end
        Workspace::DriveClient.new(subject: entity.drive_subject)
      end
    end

    def root = folder(entity.drive_root, "root")

    def inbox = folder("Inbox", root)

    def statements_folder(year) = folder(year.to_s, folder("Statements", root))

    def closes_folder(month) = folder(month, folder("Closes", root))

    # The tree's top folders, created if missing, and the root shared with
    # `share_with` unless it already is: what `setup` prints. Safe to re-run.
    def ensure_tree
      tree = { "root" => root, "inbox" => inbox, "statements" => folder("Statements", root), "closes" => folder("Closes", root) }
      share_root
      tree
    end

    def share_root
      email = entity.share_with.to_s.strip.downcase
      return if email.empty?

      shared = Array(client.permissions_list(root).permissions).any? { |p| p.email_address.to_s.downcase == email }
      client.permissions_create(root, email: email, role: "writer") unless shared
    end

    # PDFs in the Inbox, oldest first: [{id, name}].
    def inbox_pdfs
      client.paged(query: "'#{inbox}' in parents and mimeType = '#{PDF_MIME}' and trashed = false")
            .sort_by { |f| f.modified_time.to_s }
            .map { |f| { "id" => f.id, "name" => f.name } }
    end

    def download(id) = client.files_download(id)

    def create(name:, parent:, body:, content_type:, mime_type: nil)
      client.files_create(name: name, parents: [ parent ], body: body, content_type: content_type, mime_type: mime_type).id
    end

    def update(id, body:, content_type:, name: nil) = client.files_update(id, name: name, body: body, content_type: content_type).id

    def export_pdf(id) = client.files_export(id, mime_type: PDF_MIME)

    def self.link(id) = "https://drive.google.com/open?id=#{id}"

    private

    def folder(name, parent)
      @folders[[ parent, name ]] ||= begin
        query = "name = '#{name.gsub("'", "\\\\'")}' and '#{parent}' in parents and " \
                "mimeType = '#{FOLDER_MIME}' and trashed = false"
        found = client.files_list(query: query, limit: 2).files.to_a
        found.first&.id || client.files_create(name: name, parents: [ parent ], mime_type: FOLDER_MIME).id
      end
    end
  end
end
