# One distinct Content-Security-Policy violation the browser reported to
# POST /csp_reports (CspReportsController), with how often and when it was seen.
#
# The hub's policy is report-only (config/initializers/content_security_policy.rb),
# so this table is how the flip to enforcing is decided: zero genuine violations
# across 7 days of reports (studio-engine docs/FRONT_END_STANDARD.md, the CSP
# section). Read it at /admin/csp_reports or with `bin/rails csp:reports`.
#
# A row is keyed by its FINGERPRINT: page path, directive, blocked URI, source file
# and line. Query strings and URL fragments are dropped first, so one page with many
# query variants is one row, and so a token in a URL is never stored. A repeat bumps
# `count` and `last_seen_at` in one UPDATE; nothing reads then writes.
#
# Retention: CspReportRetentionJob deletes rows whose last_seen_at is older than
# RETENTION (nightly, config/recurring.yml).
class CspReport < ApplicationRecord
  RETENTION = 30.days
  MAX_FIELD = 255

  validates :fingerprint, :document_path, :directive, :blocked_uri, :first_seen_at, :last_seen_at, presence: true

  scope :top_offenders, -> { order(count: :desc, last_seen_at: :desc) }
  scope :seen_since, ->(time) { where(last_seen_at: time..) }
  scope :expired, ->(now = Time.current) { where(last_seen_at: ...(now - RETENTION.in_seconds)) }

  # report-uri sends hyphenated keys; the Reporting API (report-to) sends camelCase.
  FIELDS = {
    document: %w[document-uri documentURL],
    directive: %w[effective-directive effectiveDirective violated-directive],
    blocked: %w[blocked-uri blockedURL],
    source_file: %w[source-file sourceFile],
    line_number: %w[line-number lineNumber],
    sample: %w[script-sample sample],
    disposition: %w[disposition]
  }.freeze

  # Store one parsed report body (a Hash). Returns the row, or nil when the body
  # names no page or no directive (nothing to act on).
  def self.record!(report, user_agent: nil, now: Time.current)
    attrs = normalize(report)
    return nil if attrs[:document_path].blank? || attrs[:directive].blank?

    fingerprint = Digest::SHA256.hexdigest(attrs.values_at(:document_path, :directive, :blocked_uri, :source_file, :line_number).join("\u0000"))
    ua = user_agent.to_s[0, MAX_FIELD].presence
    upsert(
      attrs.merge(fingerprint:, user_agent: ua, count: 1, first_seen_at: now, last_seen_at: now, created_at: now, updated_at: now),
      unique_by: :fingerprint,
      on_duplicate: Arel.sql("count = csp_reports.count + 1, last_seen_at = EXCLUDED.last_seen_at, " \
                             "user_agent = EXCLUDED.user_agent, updated_at = EXCLUDED.updated_at")
    )
    find_by(fingerprint:)
  end

  def self.normalize(report)
    value = ->(key) { FIELDS.fetch(key).lazy.map { |name| report[name] }.find(&:present?) }
    line = value.(:line_number).to_s
    {
      document_path: path_only(value.(:document)),
      # "script-src-elem 'self' ..." from an old violated-directive: keep the name.
      directive: value.(:directive).to_s.split.first.to_s[0, MAX_FIELD],
      blocked_uri: blocked(value.(:blocked)),
      source_file: url_without_query(value.(:source_file)),
      line_number: line.match?(/\A\d{1,9}\z/) ? line.to_i : nil,
      sample: value.(:sample).to_s[0, MAX_FIELD].presence,
      disposition: value.(:disposition).to_s[0, 20].presence
    }
  end

  # The page's path, without host, query or fragment.
  def self.path_only(uri)
    return nil if uri.blank?

    path = URI.parse(uri.to_s).path.presence || "/"
    path[0, MAX_FIELD]
  rescue URI::InvalidURIError
    uri.to_s.split(/[?#]/).first.to_s[0, MAX_FIELD].presence
  end

  # A keyword the browser sends ("inline", "eval", "data") as is; a URL as its
  # origin and path, so a query-string token never lands in the table.
  def self.blocked(uri)
    text = uri.to_s
    return "(none)" if text.blank?
    return text[0, MAX_FIELD] unless text.include?(":")

    url_without_query(text) || text[0, MAX_FIELD]
  end

  def self.url_without_query(uri)
    return nil if uri.blank?

    text = uri.to_s
    return text[0, MAX_FIELD] unless text.include?("://")

    text.split(/[?#]/).first.to_s[0, MAX_FIELD]
  end
end
