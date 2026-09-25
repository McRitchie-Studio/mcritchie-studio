# frozen_string_literal: true

namespace :learning_loop do
  desc "Grade the last N shipped tasks (default 30). DRY RUN unless LIVE=1; LINES=0 skips the GitHub PR read."
  task backfill: :environment do
    limit = ENV.fetch("LIMIT", 30).to_i
    live = ENV["LIVE"] == "1"
    pr_reader = ENV["LINES"] == "0" ? Struct.new(:x) { def lines_for(_url) = nil }.new : nil
    Insights::TaskGrader::Backfill.run(limit: limit, live: live, pr_reader: pr_reader)
  end
end
