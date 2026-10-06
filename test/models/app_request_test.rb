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

  # rolio's production_url is a herokuapp host, not a subdomain of ours, so its
  # slug is what keeps the name from being claimed.
  test "every satellite's slug is reserved, whatever its production_url" do
    %w[rolio chain-ops turf-monster cyvasse].each do |name|
      assert_equal "That name is reserved.", AppRequest.unavailable_reason(name), "#{name} has a satellites.yml row"
    end
  end

  # chain-ops' production_url is null until chain.mcritchie.studio exists, so
  # RESERVED holds "chain" by hand.
  test "chain stays reserved for chain-ops' planned host" do
    assert_equal "That name is reserved.", AppRequest.unavailable_reason("chain")
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

  # A builder may read nothing but the card. The prompt is a customer's words and
  # never names the house rules, so the card has to: without these two an app
  # passed its card with no footer.
  test "the card requires the site footer and points the builder at the launch SOP" do
    request_row = draft(user: users(:viewer)).queue!("pawsome")
    devops = Task.find_by!(slug: request_row.task_slug).metadata.fetch("devops")

    assert_equal [
      "pawsome.mcritchie.studio serves the app the requester described",
      "pawsome.mcritchie.studio's home page renders the site footer (footer[data-site-footer])"
    ], devops.fetch("acceptance")
    context = devops.fetch("agent_context")
    assert context.end_with?(
      "\n\nWork this request by docs/agents/modules/launch-build-queue.md. " \
      "Every new app ships the site footer, and legal pages when it holds personal data: " \
      "docs/agents/system/new-app-onboarding-sop.md § 7."
    ), context
  end

  test "the requester's prompt opens the card's context, verbatim, before anything of ours" do
    prompt = "A booking site.\n\nTwo paragraphs, \"quotes\" & <tags> kept as typed"
    request_row = draft(prompt: prompt, user: users(:viewer)).queue!("pawsome")
    context = Task.find_by!(slug: request_row.task_slug).metadata.dig("devops", "agent_context")

    assert context.start_with?("Prompt from the requester, verbatim:\n\n#{prompt}\n\nSubdomain reserved: pawsome.mcritchie.studio."), context
    assert_operator context.index(prompt), :<, context.index("launch-build-queue.md")
  end

  test "the card points at docs that exist, and the footer selector is the one the engine emits" do
    AppRequest::BUILDER_POINTER.scan(%r{docs/\S+\.md}).each do |path|
      assert Rails.root.join(path).file?, "#{path} is named on every /build card and must exist"
    end
    assert_equal 2, AppRequest::BUILDER_POINTER.scan(%r{docs/\S+\.md}).size
    footer = File.read(File.join(Gem.loaded_specs.fetch("studio-engine").full_gem_path, "app/views/studio/site_footer/_footer.html.erb"))
    assert_match(/<footer[^>]*\sdata-site-footer[\s>]/, footer)
    assert_equal "footer[data-site-footer]", AppRequest::FOOTER_SELECTOR
  end

  test "the longest name the field accepts still opens a card the board accepts" do
    request_row = draft(user: users(:viewer)).queue!("a" * 30)

    assert_equal 2, Task.find_by!(slug: request_row.task_slug).devops_acceptance.size
  end

  test "a failed claim leaves no task behind" do
    draft(user: users(:alex)).queue!("pawsome")

    assert_no_difference -> { Task.count } do
      assert_raises(ActiveRecord::RecordInvalid) { draft(user: users(:viewer)).queue!("pawsome") }
    end
  end

  # The names are unregistered on purpose: the real showcase builds
  # (prisoners-dilemma, weekly-lock, rantly, portfolio, 10and5, search-position)
  # have satellites.yml rows since register-showcase-apps and
  # register-two-more-showcase-apps, so their subdomains are reserved now.
  test "an admin is exempt from the one-app rule, and their requests are showcase builds" do
    admin = users(:alex)
    assert admin.admin?
    first = draft(user: admin).queue!("coin-toss")
    second = draft(user: admin).queue!("chess-club")

    assert first.showcase? && second.showcase?
    assert_includes Task.find_by!(slug: second.task_slug).metadata.dig("devops", "agent_context"), "SHOWCASE build"
  end

  # A showcase app registered in config/satellites.yml reserves its subdomain the
  # day it is registered, so no new request can claim a name that ships there.
  test "a registered showcase app's subdomain is reserved" do
    %w[prisoners-dilemma weekly-lock rantly portfolio 10and5 search-position].each do |name|
      assert_equal "That name is reserved.", AppRequest.unavailable_reason(name),
                   "#{name} has a satellites.yml row, so its subdomain must not be claimable"
    end
  end

  test "a customer's request is never a showcase" do
    refute draft(user: users(:viewer)).queue!("league-hub").showcase?
  end

  test "a cancelled request frees its name in the database too, not only in the model" do
    first = draft(user: users(:viewer)).queue!("league-hub")
    first.update!(status: "cancelled")

    reclaimed = draft(user: users(:alex)).queue!("league-hub")
    assert reclaimed.queued?, "the holding-only unique index lets a cancelled name be claimed again"
    assert_raises(ActiveRecord::RecordNotUnique) do
      AppRequest.new(prompt: "dup", token: SecureRandom.hex(8), subdomain: "league-hub", status: "queued").save!(validate: false)
    end
  end

  test "one free app per account" do
    # A customer (non-admin). Admins are exempt — see the showcase test above.
    draft(user: users(:viewer)).queue!("first-app")

    second = draft(user: users(:viewer))
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

  test "the gallery finds a live showcase app's screenshot by convention, and nothing when it is missing" do
    live = draft(user: users(:alex)).queue!("zz-no-screenshot")
    live.update!(status: "live")
    entry = BuildGallery.showcased.find { |e| e.url.include?("zz-no-screenshot") }

    assert entry
    assert_nil entry.image, "no file at build_gallery/zz-no-screenshot.jpg, so no image"
    assert_equal "build_gallery/cyvasse.jpg", BuildGallery.configured.find { |e| e.name == "Cyvasse" }.image
  end

  test "each showcase rebuild's live card carries its screenshot" do
    %w[prisoners-dilemma weekly-lock rantly portfolio 10and5 search-position].each_with_index do |subdomain, i|
      # These names are reserved satellites, so queue! refuses them; queue a
      # placeholder and give it the real subdomain, as production holds it.
      live = draft(user: users(:alex)).queue!("zz-showcase-#{i}")
      live.update_columns(subdomain: subdomain, status: "live")
      entry = BuildGallery.showcased.find { |e| e.url == "https://#{subdomain}.mcritchie.studio" }

      assert entry, "#{subdomain} is in the gallery"
      assert_equal "build_gallery/#{subdomain}.jpg", entry.image, "#{subdomain} has a screenshot"
    end
  end

  test "the gallery leads with Cyvasse, Prisoners Dilemma and Rantly, the rest after in their usual order" do
    %w[portfolio rantly weekly-lock prisoners-dilemma].each_with_index do |subdomain, i|
      live = draft(user: users(:alex)).queue!("zz-lead-#{i}")
      live.update_columns(subdomain: subdomain, status: "live", updated_at: i.minutes.ago)
    end
    subdomains = BuildGallery.examples.map { |e| BuildGallery.subdomain(e.url) }

    assert_equal %w[cyvasse prisoners-dilemma rantly], subdomains.first(3)
    assert_equal %w[portfolio weekly-lock], subdomains.drop(3) & %w[portfolio weekly-lock], "newest first after the lead"
  end

  test "a showcase card takes its name from the config, else titleizes the subdomain" do
    assert_equal "10&5 Hospitality", BuildGallery.display_name("10and5")
    assert_equal "Weekly Lock", BuildGallery.display_name("weekly-lock")
  end

  test "a customer's live app is never in the public gallery" do
    live = draft(user: users(:viewer)).queue!("customer-app")
    live.update!(status: "live")

    refute BuildGallery.examples.any? { |e| e.url.include?("customer-app") }
  end
end
