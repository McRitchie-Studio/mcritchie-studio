# frozen_string_literal: true

require "digest"

module Books
  # Files bank statements into the books: each PDF is read, checked against the
  # bank's own totals, copied into Statements/<year>/ in the entity's Drive, and
  # recorded with its lines, which the categorizer classifies where a rule says
  # how. A statement that does not reconcile is refused whole: nothing of it is
  # recorded, and the operator is told why.
  #
  # Sources are the Inbox (the default) or PDFs handed in directly
  # (`bin/books intake --file`). The same PDF twice is skipped by its digest,
  # and an Inbox file already read is skipped by its id.
  class Intake
    Result = Struct.new(:name, :status, :statement, :problems, :warnings, keyword_init: true) do
      def to_h
        h = { "name" => name, "status" => status }
        h["problems"] = problems if problems.present?
        h["warnings"] = warnings if warnings.present?
        if statement
          entries = statement.entries.to_a
          h["statement"] = {
            "id" => statement.id, "account" => statement.account_key, "period" => statement.period_label,
            "opening" => Books.money(statement.opening_cents), "closing" => Books.money(statement.closing_cents),
            "entries" => entries.size, "unclassified" => entries.count { |e| !e.classified? }
          }
        end
        h
      end
    end

    def initialize(entity, drive: nil, parser: HuntingtonParser, text: Books::PdfText)
      @entity = entity
      @drive = drive || Books::Drive.new(entity)
      @parser = parser
      @text = text
    end

    # files: nil reads the Inbox; otherwise [{ "name" =>, "bytes" => }].
    # Statements are filed oldest first whatever order they arrive in, so the
    # continuity warnings compare each one with the statement before it.
    def call(files: nil)
      sources = (files || inbox_sources).map do |src|
        bytes = src.fetch("bytes") { @drive.download(src.fetch("id")) }
        parsed = begin
          @parser.parse(@text.call(bytes))
        rescue HuntingtonParser::Error, Books::PdfText::Error => e
          e
        end
        { name: src.fetch("name"), bytes: bytes, inbox_file_id: src["id"], parsed: parsed }
      end
      sources.sort_by { |s| s[:parsed].is_a?(Exception) ? Date.new(1900) : s[:parsed].period_start }
             .map { |s| intake_one(**s) }
    end

    private

    def inbox_sources
      seen = BookStatement.for_entity(@entity.key).where.not(inbox_file_id: nil).pluck(:inbox_file_id).to_set
      @drive.inbox_pdfs.reject { |f| seen.include?(f["id"]) }
    end

    def intake_one(name:, bytes:, inbox_file_id:, parsed:)
      return refused(name, parsed.message) if parsed.is_a?(Exception)

      sha = Digest::SHA256.hexdigest(bytes)
      if (existing = BookStatement.for_entity(@entity.key).find_by(source_sha256: sha))
        existing.update!(inbox_file_id: inbox_file_id) if inbox_file_id && existing.inbox_file_id.nil?
        return Result.new(name: name, status: "already filed", statement: existing)
      end

      account = @entity.account_for_last4(parsed.last4)
      return refused(name, "account ···#{parsed.last4} is not one of #{@entity.key}'s accounts in config/books.yml") unless account
      return refused(name, *parsed.problems) if parsed.problems.any?
      if BookStatement.for_entity(@entity.key).exists?(account_key: account.key, period_start: parsed.period_start, period_end: parsed.period_end)
        return refused(name, "a different PDF for #{account.key} #{parsed.period_start}..#{parsed.period_end} is already filed")
      end

      warnings = continuity_warnings(account, parsed)
      drive_file_id = @drive.create(name: filed_name(account, parsed), parent: @drive.statements_folder(parsed.period_end.year),
                                    body: bytes, content_type: Books::Drive::PDF_MIME)
      statement = record(account, parsed, sha: sha, name: name, inbox_file_id: inbox_file_id, drive_file_id: drive_file_id)
      Result.new(name: name, status: "filed", statement: statement, warnings: warnings)
    end

    def record(account, parsed, sha:, name:, inbox_file_id:, drive_file_id:)
      BookStatement.transaction do
        statement = BookStatement.create!(
          entity: @entity.key, account_key: account.key, period_start: parsed.period_start, period_end: parsed.period_end,
          opening_cents: parsed.opening_cents, credits_cents: parsed.credits_cents, debits_cents: parsed.debits_cents,
          service_charges_cents: parsed.service_charges_cents, closing_cents: parsed.closing_cents,
          source_sha256: sha, source_name: name, inbox_file_id: inbox_file_id, drive_file_id: drive_file_id
        )
        parsed.lines.each_with_index do |line, idx|
          decided = Categorizer.call(@entity, description: line.description, amount_cents: line.amount_cents)
          statement.entries.create!(
            entity: @entity.key, account_key: account.key, position: idx, posted_on: line.posted_on,
            amount_cents: line.amount_cents, section: line.section, description: line.description,
            category: decided.category, purpose: decided.purpose, classified_by: decided.classified_by, note: decided.note
          )
        end
        statement
      end
    end

    # A statement should open where the one before it closed, and start the day
    # after it ended. Said, not refused: statements can arrive out of order.
    def continuity_warnings(account, parsed)
      prior = BookStatement.for_entity(@entity.key).where(account_key: account.key)
                           .where(period_end: ...parsed.period_start).order(:period_end).last
      return [] unless prior

      out = []
      out << "#{account.key}: opens at #{Books.money(parsed.opening_cents)}, but #{prior.period_label} closed at #{Books.money(prior.closing_cents)}" if prior.closing_cents != parsed.opening_cents
      out << "#{account.key}: gap between #{prior.period_end} and #{parsed.period_start}" if prior.period_end + 1 < parsed.period_start
      out
    end

    def filed_name(account, parsed)
      "#{parsed.period_end.strftime('%Y-%m')} #{account.bank.capitalize} #{account.key.tr('_', ' ')} #{account.last4}.pdf"
    end

    def refused(name, *problems) = Result.new(name: name, status: "refused", problems: problems)
  end
end
