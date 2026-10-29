# frozen_string_literal: true

module Books
  # The lender package for one entity and month (`bin/books lender`): the
  # month's P&L and balance sheet, plus a Sources and Uses tab, as a native
  # Sheet and its PDF in the same Closes/<YYYY-MM>/ folder as the close. It is
  # built by the close's own code (Books::Close#build, layout :lender), so every
  # figure is the same formula over the same Ledger and the status is the same
  # FINAL or DRAFT.
  #
  # It needs the month's close to exist first, and it says when the ledger has
  # moved since that close ran (a line classified after it): the package then
  # carries figures the close does not, and the close should be re-run so the
  # two match before either goes to a lender.
  #
  # A re-run updates the same two files, like the close; their ids live on the
  # month's book_closes row (lender_sheet_file_id, lender_pdf_file_id).
  class LenderPackage < Close
    Error = Class.new(StandardError)

    # The summary keys that must agree with the close's.
    FIGURES = %w[status net_income_ytd_cents cash_cents total_assets_cents equity_cents unclassified].freeze

    def call(generated_by:)
      record = BookClose.find_by(entity: @entity.key, month: @month) or
        raise Error, "no #{@month} close for #{@entity.key} yet: run bin/books close #{@entity.key} #{@month} first"

      now = @clock.call
      workbook, checks, status = build(generated_by: generated_by, generated_at: now, layout: :lender)
      title = "#{@entity.name}: lender package #{@month}#{' (DRAFT)' if status == 'draft'}"
      notes = []

      sheet_id = write_sheet(record.lender_sheet_file_id, title, workbook.to_xlsx, notes)
      pdf_id = write_pdf(record.lender_pdf_file_id, "#{title}.pdf", @drive.export_pdf(sheet_id), notes)
      record.update!(lender_sheet_file_id: sheet_id, lender_pdf_file_id: pdf_id, lender_generated_at: now)

      summary = workbook.summary
      # A close written before a figure existed (total_assets_cents) is not held to it.
      drift = FIGURES.select { |k| record.summary.key?(k) }.reject { |k| record.summary[k] == summary[k] }
      if drift.any?
        notes << "the ledger changed since the #{@month} close ran (#{drift.join(', ')} differ): " \
                 "re-run bin/books close #{@entity.key} #{@month}, then this, before either goes to a lender"
      end
      Result.new(record: record, checks: checks, summary: summary, sheet_id: sheet_id, pdf_id: pdf_id, notes: notes)
    end
  end
end
