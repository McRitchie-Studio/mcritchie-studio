# frozen_string_literal: true

require "securerandom"

# Shared setup for the Books:: tests: a made-up entity with two accounts, a
# statement-and-lines builder, and an in-memory Drive. Nothing here names a real
# account; the chart of accounts is the real one from config/books.yml.
module BooksFixtures
  ENTITY_YAML = <<~YAML
    example:
      name: Example Studio LLC
      drive_subject: books@example.test
      drive_root: Example Books
      accounts:
        savings:
          bank: huntington
          product: Huntington Business Premier Plus MMA
          last4: "1234"
          opened_on: 2026-01-01
        checking:
          bank: huntington
          product: Huntington Business Checking 100
          last4: "5678"
          opened_on: 2026-02-01
      rules:
        - name: interest
          match: INTERESTPAYMENT
          category: interest_income
        - name: bank-fee
          match: SERVICEFEE|WIRETRANSFERFEES
          category: bank_fees
        - name: own-account-transfer
          match: INTERNETTFR(TO|FRM)CHECKING.*X+(1234|5678)
          category: internal_transfer
        - name: card-payment
          match: USBANKNAPAYMENT
          sign: out
          category: member_distribution
          purpose: Acquisition costs
        - name: wire-needs-answer
          match: FEDWIRETRANSFER
  YAML

  # A Huntington savings statement as pdf-reader prints one, made up end to end.
  HUNTINGTON_STATEMENT = <<~TXT
    THE HUNTINGTON NATIONAL BANK
               EXAMPLE STUDIO LLC                                                    Have a Question or Concern?
    Huntington Business Premier Plus MMA                                   Account: -------1234
    Statement Activity From:                   Beginning Balance                       $10,000.00
    12/01/26 to 12/31/26                       Credits (+)                               1,250.40
                                                  Other Credits                          1,250.40
                                               Debits (-)                                3,000.00
                                                  Other Debits                           3,000.00
                                               Total Service Charges (-)                    60.00
    Days in Statement Period            31     Ending Balance                           $8,190.40
    Other Credits (+)                                                                     Account:-------1234
    Date              Amount       Description
    12/15             1,200.00     INCOMING FEDWIRETRANSFER
    12/31                50.40     INTEREST PAYMENT
    Other Debits (-)                                                                      Account:-------1234
    Date              Amount       Description
    11/30             1,000.00     INTERNETTFRTO CHECKING 113026 XXXXXXX5678
    12/03             2,000.00     US BANK NA PAYMENT 261203 BILL PAYACCT XXXXXXX2383
                                   PAYEE000001 CONTINUED TEXT
    Service Charge Detail                                                                 Account:-------1234
    Date      Service Charge (-)     Waives and   Discounts (+)      Description
    12/16                50.00                                       WIRE TRANSFER FEES(OUTGOING)
    12/17                25.00         15.00                         OTHER SERVICEFEES
    Service Charge Summary                                                                Account:-------1234
    Previous Month Service Charges (-)                     $0.00
    Total Service Charges (-)                              $60.00
    Balance Activity                                                                      Account:-------1234
    Date                           Balance     Date                           Balance
    11/30                         10,000.00    12/31                          8,190.40
                                                                Statement Period from 12/01/26 to 12/31/26    Page 1 of 2
  TXT

  # Records what the books wrote, and hands back ids, like Books::Drive.
  class FakeDrive
    attr_reader :files

    def initialize(inbox: [])
      @files = {}
      @inbox_files = inbox
      @refuse_updates = false
    end

    def refuse_updates! = @refuse_updates = true

    def create(name:, parent:, body:, content_type:, mime_type: nil)
      id = "file-#{@files.size + 1}"
      @files[id] = { name: name, parent: parent, body: body, mime: mime_type || content_type, revisions: 1 }
      id
    end

    def update(id, body:, content_type:, name: nil)
      raise Google::Apis::ClientError.new("File not found: #{id}", status_code: 404) if @refuse_updates

      @files.fetch(id).merge!(body: body, name: name || @files[id][:name])
      @files[id][:revisions] += 1
      id
    end

    def export_pdf(id) = "%PDF-of-#{id}-r#{@files.fetch(id)[:revisions]}"

    def inbox = "inbox-folder"

    def ensure_tree = { "root" => "root-folder", "inbox" => inbox, "statements" => "statements", "closes" => "closes" }

    def inbox_pdfs = @inbox_files.map { |f| { "id" => f[:id], "name" => f[:name] } }

    def download(id) = @inbox_files.find { |f| f[:id] == id }.fetch(:bytes)

    def statements_folder(year) = "statements/#{year}"

    def closes_folder(month) = "closes/#{month}"
  end

  def books_config
    @books_config ||= begin
      data = YAML.safe_load_file(Rails.root.join("config/books.yml"), permitted_classes: [ Date ])
      data["entities"] = YAML.safe_load(ENTITY_YAML, permitted_classes: [ Date ])
      Books::Config.new(data)
    end
  end

  # opened: moves every account's first-statement date, for tests whose
  # statements start later than the fixture's.
  def books_entity(opened: nil)
    entity = books_config.entity("example")
    return entity unless opened

    accounts = entity.accounts.transform_values { |a| a.dup.tap { |c| c.opened_on = Date.parse(opened) } }
    entity.dup.tap { |e| e.accounts = accounts }
  end

  # lines: [[ "2026-03-05", cents, "DESCRIPTION", category, purpose ], ...]
  def book_statement!(account:, from:, to:, opening:, lines: [])
    from = Date.parse(from)
    to = Date.parse(to)
    closing = opening + lines.sum { |l| l[1] }
    statement = BookStatement.create!(
      entity: "example", account_key: account, period_start: from, period_end: to, opening_cents: opening,
      credits_cents: lines.select { |l| l[1].positive? }.sum { |l| l[1] }, debits_cents: -lines.select { |l| l[1].negative? }.sum { |l| l[1] },
      closing_cents: closing, source_sha256: SecureRandom.hex(32)
    )
    lines.each_with_index do |(date, cents, desc, category, purpose), idx|
      statement.entries.create!(entity: "example", account_key: account, position: idx, posted_on: Date.parse(date),
                                amount_cents: cents, section: cents.positive? ? "credit" : "debit", description: desc,
                                category: category, purpose: purpose, classified_by: (category && "test"))
    end
    statement
  end
end
