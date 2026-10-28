# frozen_string_literal: true

module Books
  # The server half of `bin/books`, as MailExport is of `bin/mail`: one request
  # hash in, one JSON-able answer out, run inside `heroku run … rails runner -`.
  #
  #   setup         create the Drive folder tree; answer its links
  #   status        statements per account, Inbox files not yet read, lines waiting, closes
  #   intake        file the Inbox, or the PDFs sent along as base64 (`files`)
  #   unclassified  the lines waiting for an answer
  #   classify      record what one or more lines were
  #   close         write a month's Sheet and PDF
  #
  # Every verb but status and unclassified writes. The answer never carries a
  # full account number: statements print only the last four digits. A fault
  # (Drive down, a bug) is answered as an error AND recorded with ErrorLog.
  module Export
    module_function

    def call(request, config: Books::Config.current, drive: nil)
      entity = config.entity(request.fetch("entity"))
      drive ||= Books::Drive.new(entity)
      case request["verb"]
      when "setup" then { "folders" => drive.ensure_tree.transform_values { |id| Books::Drive.link(id) },
                          "owner" => entity.drive_subject, "shared_with" => entity.share_with }
      when "status" then status(entity, drive)
      when "intake" then intake(entity, drive, request)
      when "unclassified" then { "lines" => BookEntry.for_entity(entity.key).unclassified.chronological.map { |e| line(e) } }
      when "classify" then classify(entity, request, config)
      when "close" then Books::Close.new(entity, request.fetch("month"), drive: drive, config: config)
                                    .call(generated_by: by(request)).to_h
      else { "error" => "unknown verb #{request['verb'].inspect}" }
      end
    rescue Books::Config::Error, Books::Classify::Error, Books::Drive::Error, ArgumentError, KeyError => e
      { "error" => e.message }
    rescue StandardError => e
      # Anything else is a fault, not a mistyped argument: leave a receipt in
      # /error_logs as well as the message the operator sees.
      ErrorLog.capture!(e)
      { "error" => "#{e.class}: #{e.message} (recorded in /error_logs)" }
    end

    def status(entity, drive)
      statements = BookStatement.for_entity(entity.key).order(:period_start)
      read = statements.where.not(inbox_file_id: nil).pluck(:inbox_file_id).to_set
      {
        "entity" => entity.name,
        "accounts" => entity.accounts.values.map do |a|
          own = statements.select { |s| s.account_key == a.key }
          { "account" => a.label, "statements" => own.size, "through" => own.last&.period_end&.iso8601 }
        end,
        "inbox_unread" => drive.inbox_pdfs.reject { |f| read.include?(f["id"]) }.map { |f| f["name"] },
        "unclassified" => BookEntry.for_entity(entity.key).unclassified.count,
        "closes" => BookClose.where(entity: entity.key).order(:month).map do |c|
          { "month" => c.month, "status" => c.status, "sheet" => c.sheet_file_id && Books::Drive.link(c.sheet_file_id),
            "generated_at" => c.generated_at&.iso8601 }
        end
      }
    end

    def intake(entity, drive, request)
      files = request["files"]&.map { |f| { "name" => File.basename(f.fetch("name")), "bytes" => Base64.strict_decode64(f.fetch("base64")) } }
      results = Books::Intake.new(entity, drive: drive).call(files: files)
      { "results" => results.map(&:to_h),
        "unclassified" => BookEntry.for_entity(entity.key).unclassified.chronological.map { |e| line(e) } }
    end

    def classify(entity, request, config)
      entries = Books::Classify.call(entity, ids: request.fetch("ids"), category: request["category"].presence,
                                             purpose: request["purpose"], note: request["note"], by: by(request), config: config)
      { "classified" => entries.map { |e| line(e) } }
    end

    def by(request) = request["by"].to_s.strip.presence || raise(ArgumentError, "say who is running this (--by)")

    def line(entry)
      { "id" => entry.id, "date" => entry.posted_on.iso8601, "account" => entry.account_key,
        "amount" => Books.money(entry.amount_cents), "description" => entry.description,
        "category" => entry.category, "purpose" => entry.purpose, "note" => entry.note }
    end
  end
end
