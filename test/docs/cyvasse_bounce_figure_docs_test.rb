# frozen_string_literal: true

# Guard for the Cyvasse relaunch's first-batch bounce figure.
#
# The first "Cyvasse is back" batch sent 101 emails and 13 hard-bounced
# (confirmed from production data on 2026-09-30). Three places cite it: the
# comment on Broadcast::VERIFIED_AUDIENCES, docs/email-delivery.md, and Rex's
# launch-warmup SOP. Two of them said 12 bounces and 11.9% until task
# fix-stale-cyvasse-bounce-figure, so the figure that justifies the
# verified-only audience had drifted between its own citations.
#
# This file computes the rate from the counts rather than hard-coding the
# corrected string, and asserts every citing file states that rate and no
# other bounce percentage. Change the counts and the files must follow.
#
# Standalone (no test_helper, no Rails, no database):
#   ruby -Itest test/docs/cyvasse_bounce_figure_docs_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"

class CyvasseBounceFigureDocsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  SENT = 101
  BOUNCED = 13

  CITING_FILES = %w[
    app/models/broadcast.rb
    docs/email-delivery.md
    docs/agents/agents/rex/sops/launch-warmup.md
  ].freeze

  def expected_rate
    format("%.1f%%", BOUNCED * 100.0 / SENT)
  end

  def test_rate_is_derived_from_the_counts
    assert_equal "12.9%", expected_rate
  end

  # The first batch's citations, read across line breaks: "101" followed within
  # a sentence by "bounce" and then a one-decimal rate. Later batches' rates
  # (0.8-2.4%) and the 4% limit never follow "101", so they are not read.
  FIRST_BATCH = /\b#{SENT}\b[^.|]{0,80}?bounced?[^.|%]{0,40}?(\d+\.\d%)/

  def citations(path)
    text = File.read(File.join(ROOT, path)).gsub(/\s*\n\s*#?\s*/, " ")
    text.scan(FIRST_BATCH).flatten
  end

  def test_every_citing_file_cites_the_first_batch_rate
    CITING_FILES.each do |path|
      rates = citations(path)
      refute_empty rates, "#{path} no longer cites the first batch's bounce rate; update CITING_FILES"
      rates.each do |rate|
        assert_equal expected_rate, rate, "#{path} cites #{rate} for #{BOUNCED} of #{SENT} bounced"
      end
    end
  end

  def test_no_citing_file_keeps_the_stale_figure
    CITING_FILES.each do |path|
      text = File.read(File.join(ROOT, path))
      refute text.include?("11.9%"), "#{path} still cites the stale 11.9% bounce figure"
    end
  end
end
