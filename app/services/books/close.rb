# frozen_string_literal: true

module Books
  # One month close: run the checks, build the workbook from every line since
  # the books began, and write it to Closes/<YYYY-MM>/ as a native Sheet plus
  # its PDF. A re-run updates the same two files (Drive keeps their revision
  # history), so a link already shared keeps working. The close is FINAL only
  # when every check passes; otherwise it is written as a DRAFT that says why,
  # in its title and on its Notes tab.
  class Close
    Result = Struct.new(:record, :checks, :summary, :sheet_id, :pdf_id, :notes, keyword_init: true) do
      def to_h
        {
          "month" => record.month, "status" => summary["status"], "summary" => summary,
          "checks" => checks.map(&:to_h), "notes" => notes,
          "sheet" => Books::Drive.link(sheet_id), "pdf" => Books::Drive.link(pdf_id)
        }
      end
    end

    def initialize(entity, month, drive: nil, clock: -> { Time.current }, config: Books::Config.current)
      @entity = entity
      @config = config
      @month = month
      @month_start, @month_end = Books.month_range(month)
      @drive = drive || Books::Drive.new(entity)
      @clock = clock
    end

    def call(generated_by:)
      now = @clock.call
      workbook, checks, status = build(generated_by: generated_by, generated_at: now)
      record = BookClose.find_or_initialize_by(entity: @entity.key, month: @month)
      title = "#{@entity.name}: #{@month} close#{' (DRAFT)' if status == 'draft'}"
      notes = []

      sheet_id = write_sheet(record.sheet_file_id, title, workbook.to_xlsx, notes)
      pdf_id = write_pdf(record.pdf_file_id, "#{title}.pdf", @drive.export_pdf(sheet_id), notes)

      summary = workbook.summary
      record.update!(status: status, sheet_file_id: sheet_id, pdf_file_id: pdf_id, unclassified_count: summary["unclassified"],
                     summary: summary, generated_by: generated_by, generated_at: now)
      Result.new(record: record, checks: checks, summary: summary, sheet_id: sheet_id, pdf_id: pdf_id, notes: notes)
    end

    # The checks, the status they give, and the workbook over every line through
    # month end: shared with Books::LenderPackage, so the two can never disagree
    # on a figure or on FINAL.
    def build(generated_by:, generated_at:, layout: :close)
      checker = Checks.new(@entity, @month)
      checks = checker.call
      status = checks.all?(&:ok) ? "final" : "draft"
      entries = BookEntry.for_entity(@entity.key).through(@month_end).chronological.to_a
      workbook = Workbook.new(entity: @entity, month: @month, entries: entries, statements: checker.statements,
                              checks: checks, status: status, generated_at: generated_at, generated_by: generated_by,
                              config: @config, layout: layout)
      [ workbook, checks, status ]
    end

    private

    # Update in place when this month has the file already. If Drive refuses the
    # update (the file was deleted, or moved out of reach), make a new one and
    # say that the link changed.
    def write_sheet(existing_id, title, xlsx, notes)
      if existing_id
        begin
          return @drive.update(existing_id, body: xlsx, content_type: Books::Drive::XLSX_MIME, name: title)
        rescue Google::Apis::ClientError => e
          notes << "the previous Sheet could not be updated (#{e.message}); a new one was made, so its link changed"
        end
      end
      @drive.create(name: title, parent: @drive.closes_folder(@month), body: xlsx,
                    content_type: Books::Drive::XLSX_MIME, mime_type: Books::Drive::SHEET_MIME)
    end

    def write_pdf(existing_id, name, pdf, notes)
      if existing_id
        begin
          return @drive.update(existing_id, body: pdf, content_type: Books::Drive::PDF_MIME, name: name)
        rescue Google::Apis::ClientError => e
          notes << "the previous PDF could not be updated (#{e.message}); a new one was made, so its link changed"
        end
      end
      @drive.create(name: name, parent: @drive.closes_folder(@month), body: pdf, content_type: Books::Drive::PDF_MIME)
    end
  end
end
