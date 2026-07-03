namespace :insights do
  desc "Generate docs/agents/shared/insights.md from the Insight Bank (ActionGrade.banked)"
  task doc: :environment do
    count = Insights::DocGenerator.generate!(at: Time.current)
    puts "insights:doc — wrote #{count} banked #{count == 1 ? 'insight' : 'insights'} to " \
         "#{Insights::DocGenerator.default_path}"
  end
end
