# frozen_string_literal: true

module MarketingKit
  # Puts one recipe's built .xlsx into Drive as a native Google Sheet, in the
  # recipe's drive.folder (its entity's Records folder), as drive.subject.
  #
  # - The folder is found by its exact name, or created; a new folder is shared
  #   by name with the standing pair (the Workspace's admin and
  #   alex@mcritchie.studio). Two folders of one name stop the publish.
  # - The sheet is found by its exact name in that folder. A new one is created
  #   and shared the same way. An existing one is replaced in place (its link and
  #   any bound script stay) ONLY when its last editor is drive.subject: a person
  #   who edits a live sheet is never overwritten. They edited it → Edited, and
  #   the caller carries their changes into the recipe, or passes force: true
  #   after reading them.
  # - Stamp columns become real checkboxes through the Sheets API (the .xlsx
  #   import drops them). If the API is off, the sheet still publishes and the
  #   result says so.
  #
  # dry_run: true reads Drive and reports, writing nothing.
  class SheetPublisher
    FOLDER = "application/vnd.google-apps.folder"
    SHEET = "application/vnd.google-apps.spreadsheet"
    XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    # The Sheet Template's data rows: 9 to 999 (1-based), as the API counts them.
    DATA_ROWS = (8...999).freeze

    class Edited < Error; end

    Result = Data.define(:action, :detail, :id)

    attr_reader :results, :sheet_id

    def initialize(recipe, xlsx:, drive: Workspace::DriveClient.new(subject: recipe.drive[:subject]),
                   sheets: Workspace::SheetsClient.new(subject: recipe.drive[:subject]), dry_run: false, force: false)
      @recipe = recipe
      @xlsx = xlsx
      @drive = drive
      @sheets = sheets
      @dry_run = dry_run
      @force = force
      @results = []
    end

    def run
      folder = find_or_create_folder
      @sheet_id = put_sheet(folder)
      stamp_checkboxes if @sheet_id && !@dry_run
      self
    end

    def url = @sheet_id && "https://docs.google.com/spreadsheets/d/#{@sheet_id}/edit"

    # alex@<the subject's domain> and alex@mcritchie.studio, once each.
    def share_with
      domain = @recipe.drive[:subject].to_s.split("@").last
      ["alex@#{domain}", Spec::ALWAYS_SHARE].uniq
    end

    private

    def note(action, detail, id = nil) = results << Result.new(action, detail, id)

    def q(text) = text.to_s.gsub("\\") { "\\\\" }.gsub("'") { "\\'" }

    def find_or_create_folder
      name = @recipe.drive[:folder]
      hits = @drive.paged(query: "name = '#{q(name)}' and mimeType = '#{FOLDER}' and trashed = false").to_a
      raise Error, "#{hits.size} folders are named #{name.inspect}; merge them in Drive first" if hits.size > 1
      return hits.first.id if hits.one?

      note(:create, "folder #{name}")
      return nil if @dry_run

      @drive.files_create(name: name, parents: [], mime_type: FOLDER).id.tap { |id| share(id) }
    end

    def put_sheet(folder)
      name = @recipe.name
      hits = folder ? @drive.paged(query: "'#{q(folder)}' in parents and name = '#{q(name)}' and trashed = false").reject { |f| f.mime_type == FOLDER } : []
      raise Error, "two files are named #{name.inspect} in #{@recipe.drive[:folder]}; merge them first" if hits.size > 1

      return create_sheet(name, folder) if hits.empty?

      replace_sheet(hits.first, name)
    end

    def create_sheet(name, folder)
      note(:create, name)
      return nil if @dry_run

      @drive.files_create(name: name, parents: [folder], mime_type: SHEET, body: File.binread(@xlsx), content_type: XLSX).id.tap { |id| share(id) }
    end

    def replace_sheet(file, name)
      editor = last_editor(file.id)
      # Fails closed: Drive can omit lastModifyingUser (a deleted or hidden editor).
      if editor != @recipe.drive[:subject].to_s.downcase && !@force
        raise Edited, "#{name} was last edited by #{editor || 'an unknown user'}; export it, carry their changes into the recipe, " \
                      "then publish again (or pass --force once you have)"
      end

      note(:update, name, file.id)
      @drive.files_update(file.id, body: File.binread(@xlsx), content_type: XLSX) unless @dry_run
      file.id
    end

    def last_editor(id)
      @drive.service.get_file(id, fields: "lastModifyingUser(emailAddress)").last_modifying_user&.email_address&.downcase
    end

    def share(id)
      have = Array(@drive.permissions_list(id).permissions).filter_map { |p| p.email_address&.downcase }
      share_with.each do |email|
        next note(:shared, email) if have.include?(email)

        @drive.permissions_create(id, email: email)
        note(:share, email)
      end
    end

    def stamp_checkboxes
      stamps = @recipe.stamps
      return if stamps.empty?

      requests = stamps.map do |s|
        Workspace::SheetsClient.checkboxes(sheet_id: @sheets.sheet_id(@sheet_id, s[:tab]), rows: DATA_ROWS, column: s[:column])
      end
      @sheets.batch_update(@sheet_id, requests)
      note(:checkboxes, stamps.map { |s| "#{s[:tab]} → #{s[:target]}" }.join(", "))
    rescue Workspace::SheetsClient::Disabled => e
      note(:skipped, "checkboxes: #{e.message}")
    end
  end
end
