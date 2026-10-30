# frozen_string_literal: true

require "test_helper"
require_relative "../support/marketing_kit_fixtures"

# [integration] MarketingKit::Build across its file-system boundary with a
# `title` palette key: the files it writes to disk (guidelines page, Doc
# templates, Brand Guide, slides payload) carry the title colour on their
# titles, and keep primary for bars and table heads. Chrome and Python are not
# run (pdf: false, office: false); the slides payload is checked as Office
# would receive it.
class MarketingKitTitleColourBuildTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  TITLE = "#C8661F"
  PRIMARY = "#2F6B4F"

  test "a kit built with a title key writes titles in it and bars in primary" do
    title = ->(d) { d["palette"] << { "key" => "title", "name" => "Forge Orange", "hex" => TITLE, "role" => "Titles" } }
    load_kit(edit: title) do |spec|
      Dir.mktmpdir do |out|
        MarketingKit::Build.new(spec, out: out, pdf: false, office: false).run
        read = ->(*rel) { File.read(File.join(out, *rel)) }

        guidelines = read.call("guidelines", "guidelines.html")
        assert_includes guidelines, "h2 { font-weight:800; color:#{TITLE};"
        assert_includes guidelines, "background:#{PRIMARY}; }", "the page bar stays primary"

        general = read.call("templates", "RF Template — General.html")
        assert_includes general, "font-weight:700;color:#{TITLE};font-size:30pt"
        proposal = read.call("templates", "RF Template — Proposal.html")
        assert_includes proposal, "font-weight:700;color:#{TITLE};font-size:40pt"
        assert_includes proposal, "background-color:#{PRIMARY};padding:12pt 18pt"

        guide = read.call("docs", "Brand Guide.html")
        assert_match(/<h1 style="[^"]*color:#{TITLE}/, guide)
        assert_match(/<th style="[^"]*background-color:#{PRIMARY}/, guide)
        assert_includes guide, "Forge Orange", "the title swatch is listed with the palette"

        assert_equal TITLE, MarketingKit::Office.new(spec).slides_payload.dig(:colours, :title)
      end
    end
  end
end
