# frozen_string_literal: true

require "test_helper"
require_relative "../support/marketing_kit_fixtures"

# [integration] MarketingKit::Build with Office on, across the Python boundary (task cw-proposal-page-layout): the
# Proposal is drawn as a Word file, filed in 05 Templates as kind "word", and the publisher sends it to Drive as a
# Word upload stored as a Google Doc. The Slides, Sheet and tracker writers are stubbed; the proposal runs for real.
class MarketingKitProposalBuildTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  test "a build files the Proposal as a Word file the publisher stores as a Google Doc" do
    with_kit do |path|
      dir = File.dirname(path)
      Dir.glob(File.join(dir, "{logos/png,photos}/*")).each { |f| File.binwrite(f, PNG) }
      spec = MarketingKit::Spec.load(path)
      real = MarketingKit::Office.new(spec)
      office = Class.new do
        define_method(:slides_name) { "RF Slides Template" }
        %i[write_slides write_sheet].each { |m| define_method(m) { |p| File.write(p, "x") && p } }
        define_method(:write_tracker) { |_inventory, p| File.write(p, "x") && p }
        define_method(:write_proposal) { |p| real.write_proposal(p) }
      end.new

      MarketingKit::Office.stub(:new, office) do
        Dir.mktmpdir do |out|
          build = MarketingKit::Build.new(spec, out: out, pdf: false).run
          entry = build.entries.find { |e| e.name == "RF Proposal Template" }
          assert entry, "the Proposal template is in the manifest"
          assert_equal [MarketingKit::Layout::TEMPLATES, "word", "Template"], [entry.folder, entry.kind, entry.type]
          assert_equal ".docx", File.extname(entry.local)
          assert_equal "PK", File.binread(entry.local, 2), "a real Word (zip) file"

          stored, sent = MarketingKit::Publisher::NATIVE.fetch("word")
          assert_equal "application/vnd.google-apps.document", stored
          assert_equal MarketingKit::Build.mime(entry.local), sent
        end
      end
    end
  end
end
