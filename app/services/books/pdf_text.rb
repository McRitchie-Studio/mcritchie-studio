# frozen_string_literal: true

require "pdf-reader"

module Books
  # A PDF's text, page by page, joined with form feeds (the parser ends a
  # section at a page break). pdf-reader is pure Ruby: a dyno has no poppler.
  module PdfText
    Error = Class.new(StandardError)

    module_function

    def call(bytes)
      PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\f\n")
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
      raise Error, "not a readable PDF: #{e.message}"
    end
  end
end
