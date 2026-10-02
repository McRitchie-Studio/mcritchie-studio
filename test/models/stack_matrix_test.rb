require "test_helper"

# [unit] StackMatrix — the /stack/matrix grid is read from each client's derived
# stack and hosting, grouped by category, and its MRR counts priced tiers only.
#
# Tier keys are read from config/workspace_packages.yml rather than named, so
# the tests hold when the ladder is renamed.
class StackMatrixTest < ActiveSupport::TestCase
  def paid_packages = WorkspacePackage.all.select { |package| package.priced? && !package.free? }

  def internal_client(**attrs)
    StackClient.new({ slug: "studio", name: "McRitchie Studio", tier: StackClient::INTERNAL }.merge(attrs))
  end

  test "a cell is ms, own, or nil, from the client's stack and hosting" do
    client = internal_client(extra_software: %w[heroku stripe], hosting: { "heroku" => "own" })
    other = internal_client(slug: "industries", name: "McRitchie Industries", extra_software: %w[resend])
    matrix = StackMatrix.new([ client, other ])

    assert_equal "own", matrix.cell(client, "heroku"), "the client's override beats the config default"
    assert_equal "own", matrix.cell(client, "stripe")
    assert_equal "ms", matrix.cell(other, "resend"), "Resend defaults to our account"
    assert_nil matrix.cell(client, "resend")
  end

  test "rows are only software some client runs, grouped in category order" do
    client = internal_client(extra_software: %w[stripe heroku 1password anthropic])
    groups = StackMatrix.new([ client ]).groups

    assert_equal [ "App", "Payments & crypto", "AI", "Secrets" ], groups.map(&:category)
    assert_equal %w[heroku stripe anthropic 1password], groups.flat_map(&:software)
    refute_includes groups.flat_map(&:software), "x", "nobody runs X, so it has no row"
  end

  test "the page leads with Platform & Email, then App, then Data, each in Alex's order" do
    client = internal_client(extra_software: %w[cloudflare github redis squarespace heroku resend postgres google])
    groups = StackMatrix.new([ client ]).groups

    assert_equal [ "Platform & Email", "App", "Data" ], groups.map(&:category)
    assert_equal [ %w[google resend squarespace], %w[heroku github], %w[postgres redis cloudflare] ],
                 groups.map(&:software)
  end

  test "Pro and up carry the Squarespace domain in their stack; Vibe's subdomain does not" do
    assert_includes WorkspacePackage.find("pro").software_keys, "squarespace"
    assert_includes WorkspacePackage.find("growth").software_keys, "squarespace"
    refute_includes WorkspacePackage.find("vibe").software_keys, "squarespace"
  end

  test "a software key with no category falls into Other, not off the page" do
    assert_equal "Other", StackMatrix.category_for("brand-new-thing")
    assert_equal "Platform & Email", StackMatrix.category_for(:resend)
  end

  test "unused software lists configured keys no stack has" do
    matrix = StackMatrix.new([ internal_client(extra_software: %w[heroku]) ])

    refute_includes matrix.unused_software, "heroku"
    assert_includes matrix.unused_software, "moonpay"
  end

  test "hosting mode reads the app's Heroku, and is nil with no app" do
    ms = internal_client(extra_software: %w[heroku])
    own = internal_client(slug: "industries", name: "Industries", extra_software: %w[heroku], hosting: { "heroku" => "own" })
    none = internal_client(slug: "family", name: "Family")
    matrix = StackMatrix.new([ ms, own, none ])

    assert_equal "MS-hosted", matrix.hosting_mode(ms)
    assert_equal "White label", matrix.hosting_mode(own)
    assert_nil matrix.hosting_mode(none)
  end

  test "MRR sums priced tiers only; internal and free clients add nothing" do
    paid = paid_packages.first(2)
    assert_operator paid.size, :>=, 1, "the ladder has at least one paid tier"
    slugs = %w[turf-monster commercial-welding]
    clients = paid.each_with_index.map { |package, i| StackClient.new(slug: slugs[i], name: slugs[i], tier: package.key) }
    clients << internal_client
    free = WorkspacePackage.all.find(&:free?)
    clients << StackClient.new(slug: "family", name: "Family", tier: free.key) if free

    matrix = StackMatrix.new(clients)

    assert_equal paid.sum(&:price_monthly), matrix.mrr
    assert_equal paid.size, matrix.paying_clients.size
  end

  test "price labels: Internal, Free, $n/mo, and Custom for an unpriced tier" do
    package = paid_packages.first
    priced = StackClient.new(slug: "turf-monster", name: "Turf", tier: package.key)
    matrix = StackMatrix.new([ priced ])

    assert_equal "Internal", matrix.price_label(internal_client)
    assert_equal "$#{package.price_monthly.to_i.to_fs(:delimited)}/mo", matrix.price_label(priced)

    custom = WorkspacePackage.new({ "key" => "custom", "name" => "Custom" })
    priced.stub(:package, custom) do
      assert_equal "Custom", matrix.price_label(priced)
      assert_equal 0, StackMatrix.new([ priced ]).mrr, "a tier with no list price adds nothing to MRR"
    end

    free = WorkspacePackage.new({ "key" => "free", "name" => "Free", "price_monthly" => 0 })
    priced.stub(:package, free) { assert_equal "Free", matrix.price_label(priced) }
  end
end
