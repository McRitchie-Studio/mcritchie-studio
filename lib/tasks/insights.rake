namespace :insights do
  desc "Generate docs/agents/shared/insights.md from the Insight Bank (ActionGrade.banked)"
  task doc: :environment do
    count = Insights::DocGenerator.generate!(at: Time.current)
    db = ActiveRecord::Base.connection_db_config.configuration_hash

    puts "insights:doc — wrote #{count} banked #{count == 1 ? 'insight' : 'insights'} to " \
         "#{Insights::DocGenerator.default_path}"

    # NAME THE SOURCE. Running this from a desk worktree or any local checkout reads
    # that checkout's EMPTY database and writes a confident "0 banked insights",
    # trading a stale doc for a false one while looking like a success. The count
    # alone cannot distinguish that from a genuinely empty bank — the database it
    # came from can. See docs/agents/agents/alex/sops/share-insights.md.
    puts "insights:doc — read the bank from #{db[:database]} on #{db[:host] || 'localhost'}"
    if count.zero?
      warn "insights:doc — WARNING: wrote 0 insights. If that database is not the BOARD's, " \
           "this doc is now FALSE; do not commit it. See docs/agents/agents/alex/sops/share-insights.md."
    end
  end
end
