require "test_helper"

# [unit] AppRequest — the /build funnel's record. The subdomain rules are the
# promise we make publicly (<name>.mcritchie.studio), so each is pinned here:
# format, reserved names (including every satellite's), uniqueness among
# holding requests, and one free app per account. Queueing opens the board task
# in the same transaction.
class AppRequestTest < ActiveSupport::TestCase
  def draft(**attrs) = AppRequest.create!({ prompt: "A booking site for my groomer" }.merge(attrs))

  test "a draft needs only a prompt, and mints its own secret token" do
    d = draft

    assert d.draft?
    assert_operator d.token.length, :>=, 20
    assert_nil d.subdomain
    refute AppRequest.new(prompt: "  ").valid?
    refute AppRequest.new(prompt: "x" * (AppRequest::PROMPT_LIMIT + 1)).valid?
  end

  test "subdomain format: 3-30 of a-z, 0-9, hyphen, alphanumeric at both ends" do
    %w[abc pawsome-grooming a1b app-2026].each do |ok|
      assert_nil AppRequest.unavailable_reason(ok), "#{ok} should be claimable"
    end
    [ "ab", "a" * 31, "--", "!!", "" ].each do |bad|
      assert_match(/letters, numbers or hyphens/, AppRequest.unavailable_reason(bad), "#{bad.inspect} should be refused")
    end
  end

  test "names are cleaned the way the field cleans them: case, runs of symbols, edge hyphens" do
    {
      "  Pawsome.mcritchie.studio " => "pawsome",
      "Uber for Dogs!" => "uber-for-dogs",
      "asda ddadd   d" => "asda-ddadd-d",
      "-My_App--" => "my-app",
      "ab.cd" => "ab-cd"
    }.each { |typed, name| assert_equal name, AppRequest.normalize_subdomain(typed), typed.inspect }
  end

  test "every example name the field types is a valid, unreserved name" do
    assert_equal 20, AppRequest::EXAMPLE_NAMES.size
    assert_equal AppRequest::EXAMPLE_NAMES.uniq, AppRequest::EXAMPLE_NAMES
    AppRequest::EXAMPLE_NAMES.each do |example|
      assert_nil AppRequest.unavailable_reason(example), "#{example} would teach a name we refuse"
    end
  end

  test "reserved names include ours and every satellite's subdomain" do
    %w[www api admin build stack].each { |name| assert_equal "That name is reserved.", AppRequest.unavailable_reason(name) }
    satellite_hosts = YAML.safe_load_file(Rails.root.join("config/satellites.yml"))["satellites"]
                          .map { |s| URI.parse(s["production_url"].to_s).host.to_s }
                          .select { |h| h.end_with?(".mcritchie.studio") }
                          .map { |h| h.delete_suffix(".mcritchie.studio") }
    refute_empty satellite_hosts
    satellite_hosts.each { |name| assert_equal "That name is reserved.", AppRequest.unavailable_reason(name), "#{name} is a live satellite" }
  end

  test "a claimed name is taken; a cancelled request releases it" do
    first = draft(user: users(:alex)).queue!("pawsome")
    assert_equal "That name is taken.", AppRequest.unavailable_reason("pawsome")

    first.update!(status: "cancelled")
    assert_nil AppRequest.unavailable_reason("pawsome")
  end

  test "queue! claims the name, queues the request and opens a board task, together" do
    request_row = draft(user: users(:alex)).queue!("pawsome")

    assert request_row.queued?
    assert_equal "pawsome.mcritchie.studio", request_row.host
    task = Task.find_by!(slug: request_row.task_slug)
    assert_equal "designed", task.stage
    assert_equal "Build Launch App pawsome", task.title
    assert_includes task.metadata.dig("devops", "agent_context"), "A booking site for my groomer"
  end

  test "a failed claim leaves no task behind" do
    draft(user: users(:alex)).queue!("pawsome")

    assert_no_difference -> { Task.count } do
      assert_raises(ActiveRecord::RecordInvalid) { draft(user: users(:viewer)).queue!("pawsome") }
    end
  end

  test "one free app per account" do
    draft(user: users(:alex)).queue!("first-app")

    second = draft(user: users(:alex))
    error = assert_raises(ActiveRecord::RecordInvalid) { second.queue!("second-app") }
    assert_match(/one app/, error.message)
  end

  test "a draft belongs to whoever signs in first, then only to them" do
    d = draft
    assert d.claimable_by?(users(:alex))

    d.update!(user: users(:alex))
    assert d.claimable_by?(users(:alex))
    refute d.claimable_by?(users(:viewer))
  end
end
