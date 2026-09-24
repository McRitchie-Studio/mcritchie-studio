require "redcarpet"

module Workspace
  # Turns a message written in markdown into the MIME a Gmail draft carries:
  # multipart/alternative, an HTML part for Gmail and a plain-text part for
  # everything else.
  #
  # Markdown is the drafting language because it is what an agent writes in
  # chat: `**[Claude](https://claude.ai)**` becomes a bold link, a blank line a
  # paragraph break, a single line break a <br>.
  #
  # Two safety choices, both in the renderer rather than left to the author:
  #
  #   escape_html     raw HTML in the source is shown as text, never rendered —
  #                   a pasted <script> or tracking pixel cannot ride into a
  #                   draft that a human then sends under their own name.
  #   safe_links_only only http(s)/mailto/ftp links render as anchors, so a
  #                   `javascript:` link degrades to plain text.
  #
  # Hand the result to GmailClient#drafts_create as PLAIN MIME: the gem does
  # the base64url encoding itself (see GmailClient#draft_for).
  class DraftMessage
    MARKDOWN_OPTIONS = { autolink: true, no_intra_emphasis: true, strikethrough: true }.freeze
    RENDER_OPTIONS = { escape_html: true, hard_wrap: true, safe_links_only: true }.freeze

    attr_reader :from, :to, :cc, :subject, :markdown, :in_reply_to, :references

    def initialize(from:, to:, subject:, markdown:, cc: nil, signature: nil, in_reply_to: nil, references: nil)
      @from = from
      @to = Array(to).flat_map { |address| address.to_s.split(",") }.map(&:strip).reject(&:empty?)
      @cc = Array(cc).flat_map { |address| address.to_s.split(",") }.map(&:strip).reject(&:empty?)
      @subject = subject.to_s.strip
      @markdown = [ markdown.to_s.strip, signature.to_s.strip.presence ].compact.join("\n\n")
      @in_reply_to = in_reply_to.presence
      @references = references.presence

      raise ArgumentError, "a draft needs at least one recipient" if @to.empty?
      raise ArgumentError, "a draft needs a body" if markdown.to_s.strip.empty?
    end

    def html
      renderer = Redcarpet::Render::HTML.new(**RENDER_OPTIONS)
      Redcarpet::Markdown.new(renderer, **MARKDOWN_OPTIONS).render(markdown)
    end

    # What a text-only client shows. Links keep their URL in parentheses so the
    # destination is never lost; emphasis markers are dropped.
    def text
      markdown
        .gsub(/\[([^\]]+)\]\(([^)\s]+)\)/) { "#{Regexp.last_match(1)} (#{Regexp.last_match(2)})" }
        .gsub(/(\*\*|__)(.+?)\1/, '\2')
        .gsub(/(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])/, '\1')
        .gsub(/~~(.+?)~~/, '\1') + "\n"
    end

    def to_mime
      message = Mail.new
      message.from = from
      message.to = to
      message.cc = cc if cc.any?
      message.subject = subject
      message["In-Reply-To"] = in_reply_to if in_reply_to
      message["References"] = references if references

      plain = text
      rich = html
      message.text_part = Mail::Part.new do
        content_type "text/plain; charset=UTF-8"
        body plain
      end
      message.html_part = Mail::Part.new do
        content_type "text/html; charset=UTF-8"
        body rich
      end
      without_message_id(message.to_s)
    end

    private

    # The Mail gem stamps a Message-ID built from THIS machine's hostname
    # ("<…@mac.lan.mail>"), which would leak where the draft was composed.
    # A draft saved without one is given one by Gmail, so the header is dropped from
    # the top-level block only — never from a part.
    def without_message_id(mime)
      head, separator, body = mime.partition("\r\n\r\n")
      kept = head.split("\r\n").reject { |line| line.start_with?("Message-ID:") }
      kept.join("\r\n") + separator + body
    end
  end
end
