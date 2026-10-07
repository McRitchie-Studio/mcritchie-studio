require "test_helper"

class NewsTest < ActiveSupport::TestCase
  # --- Slug ---

  test "slug is generated on create" do
    news = News.create!(title: "Test slug generation")
    assert news.slug.present?
    assert news.slug.start_with?("news-")
  end

  test "slug is immutable after creation" do
    news = news(:new_article)
    original_slug = news.slug
    news.update!(title: "Changed title")
    assert_equal original_slug, news.slug
  end

  test "to_param returns slug" do
    news = news(:new_article)
    assert_equal news.slug, news.to_param
  end

  # --- Stage transitions ---

  test "new article can be reviewed" do
    news = news(:new_article)
    news.review!
    assert_equal "reviewed", news.stage
    assert_not_nil news.reviewed_at
  end

  test "reviewed article can be processed" do
    news = news(:reviewed_article)
    news.process_news!
    assert_equal "processed", news.stage
    assert_not_nil news.processed_at
  end

  test "processed article can be refined" do
    news = news(:processed_article)
    news.refine!
    assert_equal "refined", news.stage
    assert_not_nil news.refined_at
  end

  test "refined article can be concluded" do
    news = news(:refined_article)
    news.conclude!
    assert_equal "concluded", news.stage
    assert_not_nil news.concluded_at
  end

  test "concluded article can be archived" do
    news = news(:concluded_article)
    news.archive!
    assert_equal "archived", news.stage
    assert_not_nil news.archived_at
  end

  # --- Free movement ---

  test "article can move to any stage" do
    news = news(:new_article)
    news.update!(stage: "refined")
    assert_equal "refined", news.stage
    assert_not_nil news.refined_at
    news.update!(stage: "new")
    assert_equal "new", news.stage
  end

  test "stage change sets appropriate timestamp" do
    news = news(:new_article)
    news.update!(stage: "concluded")
    assert_not_nil news.concluded_at
    news.update!(stage: "archived")
    assert_not_nil news.archived_at
  end

  # --- Position ---

  test "position is auto-set on create" do
    news = News.create!(title: "Auto position test", stage: "new")
    assert_not_nil news.position
  end

  test "stage change gives highest position in target stage" do
    news = news(:new_article)
    existing = News.where(stage: "reviewed").maximum(:position) || 0
    news.update!(stage: "reviewed")
    assert_equal "reviewed", news.stage
    assert_equal existing + 100, news.position
  end

  test "new articles get appended to end of stage" do
    n1 = News.create!(title: "First", stage: "new")
    n2 = News.create!(title: "Second", stage: "new")
    assert n2.position > n1.position
  end

  # --- Validations ---

  test "title is required" do
    news = News.new(title: nil)
    assert_not news.valid?
    assert_includes news.errors[:title], "can't be blank"
  end

  test "stage must be valid" do
    news = news(:new_article)
    assert_raises ActiveRecord::RecordInvalid do
      news.update!(stage: "invalid_stage")
    end
  end

  # --- Scopes ---

  test "by_stage returns only matching stage" do
    results = News.by_stage("new")
    results.each { |n| assert_equal "new", n.stage }
  end

  test "ordered scope returns records" do
    results = News.ordered
    assert results.any?
  end

  # --- News::Review service ---

  test "Review service updates fields and advances stage" do
    article = news(:new_article)
    result = News::Review.new(article).call(
      primary_person: "Travis Kelce",
      primary_team: "Kansas City Chiefs",
      primary_action: "signed",
      secondary_person: nil,
      secondary_team: nil,
      article_image_url: "https://example.com/image.jpg"
    )

    assert_equal "reviewed", result.stage
    assert_equal "Travis Kelce", result.primary_person
    assert_equal "Kansas City Chiefs", result.primary_team
    assert_equal "signed", result.primary_action
    assert_equal "https://example.com/image.jpg", result.article_image_url
    assert_not_nil result.reviewed_at
  end

  # --- News::Process service ---

  test "Process service generates slugs and advances stage" do
    article = news(:reviewed_article)
    result = News::Process.new(article).call

    assert_equal "processed", result.stage
    assert_equal "christian-pulisic", result.primary_person_slug
    # "USA" names no team row (the fixture team is united-states): no slug is written.
    assert_nil result.primary_team_slug
    assert_not_nil result.processed_at
  end

  test "Process service handles nil person/team gracefully" do
    article = news(:new_article)
    article.update!(stage: "reviewed")
    result = News::Process.new(article).call

    assert_equal "processed", result.stage
    assert_nil result.primary_person_slug
    assert_nil result.primary_team_slug
  end

  # --- News::Refine service ---

  test "Refine service updates fields and advances stage" do
    article = news(:processed_article)
    result = News::Refine.new(article).call(
      title_short: "Messi named to squad",
      summary: "Argentina finalizes World Cup roster.",
      feeling: "excited",
      feeling_emoji: "🔥",
      what_happened: "Argentina announced their final squad."
    )

    assert_equal "refined", result.stage
    assert_equal "Messi named to squad", result.title_short
    assert_equal "excited", result.feeling
    assert_not_nil result.refined_at
  end

  # --- News::Conclude service ---

  test "Conclude service updates fields and advances stage" do
    article = news(:refined_article)
    result = News::Conclude.new(article).call(
      opinion: "Brazil needs stability at the top.",
      callback_ideas: ["Watch for the new manager announcement.", "Rank Brazil's coaching candidates.", "Poll: Can Brazil win the World Cup?"]
    )

    assert_equal "concluded", result.stage
    assert_equal "Brazil needs stability at the top.", result.opinion
    assert_equal 3, result.callback_ideas.size
    assert_equal "Watch for the new manager announcement.", result.callback_ideas.first
    assert_not_nil result.concluded_at
  end

  # --- Full pipeline ---

  test "[unit] Process writes the slug of a team the hub holds" do
    article = news(:reviewed_article)
    article.update!(primary_team: "Brazil")

    assert_equal "brazil", News::Process.new(article).call.primary_team_slug
  end

  test "full pipeline new through concluded" do
    article = News.create!(title: "Test pipeline article", author: "Test")

    News::Review.new(article).call(
      primary_person: "Joe Burrow",
      primary_team: "Cincinnati Bengals",
      primary_action: "injured",
      secondary_person: nil,
      secondary_team: nil,
      article_image_url: nil
    )
    assert_equal "reviewed", article.stage

    News::Process.new(article).call
    assert_equal "processed", article.stage
    assert_equal "joe-burrow", article.primary_person_slug
    # No Bengals team row in the fixtures: the slug stays blank rather than dangling.
    assert_nil article.primary_team_slug

    News::Refine.new(article).call(
      title_short: "Burrow injured",
      summary: "Joe Burrow suffers knee injury.",
      feeling: "concerned",
      feeling_emoji: "😟",
      what_happened: "Burrow went down in practice."
    )
    assert_equal "refined", article.stage

    News::Conclude.new(article).call(
      opinion: "Bengals season could be over.",
      callback: "MRI results expected tomorrow."
    )
    assert_equal "concluded", article.stage
  end
end
