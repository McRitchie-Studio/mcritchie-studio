namespace :insights do
  desc "Generate docs/agents/shared/insights.md from the Insight Bank (ActionGrade.banked)"
  task doc: :environment do
    path = Insights::DocGenerator.generate!(at: Time.current)
    count = ActionGrade.banked.count
    puts "insights:doc — wrote #{count} banked #{count == 1 ? 'insight' : 'insights'} to #{path}"
  end
end
