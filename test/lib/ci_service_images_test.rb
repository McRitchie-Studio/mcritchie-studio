# frozen_string_literal: true
# Guard test for the service containers in .github/workflows/reusable-ci.yml: the
# image every database lane pulls, and where it pulls it from.
#
# Why this test exists: `image: postgres` resolves to Docker Hub, and Docker Hub
# meters anonymous pulls per IP. GitHub's hosted runners share their IPs, so on a
# busy afternoon every lane with a database dies at setup with `toomanyrequests`
# before a single test runs (three consecutive runs on 2026-10-09). ECR Public, the
# mirror that replaced it, then answered `toomanyrequests: Data limit exceeded` five
# times on 2026-10-10 and blocked the release. So the lanes pull from GitHub's own
# registry: .github/workflows/mirror-ci-images.yml copies the official image to
# ghcr.io/mcritchie-studio, and each service block logs in with the run's token. A
# bare name, a Docker Hub or ECR name, a missing login, a token without
# `packages: read`, an image the mirror does not copy, or a drift between the three
# service blocks puts an anonymous quota back on the critical path, so this asserts
# each directly.
#
# The name reaches the service blocks through the `postgres-image` input, so the
# guard reads the workflow as a bare call runs it (every input at its default) and
# holds each `*-image` input default to the mirror as well.
#
# Run directly:
#   ruby -Itest test/lib/ci_service_images_test.rb
# Also picked up by the normal `bin/rails test` sweep.
require "minitest/autorun"
require "yaml"
require_relative "../../bin/lib/ci_suite_workflow"

class CiServiceImagesTest < Minitest::Test
  WORKFLOW = File.expand_path("../../.github/workflows/reusable-ci.yml", __dir__)
  MIRROR_WORKFLOW = File.expand_path("../../.github/workflows/mirror-ci-images.yml", __dir__)
  MIRROR = "ghcr.io/mcritchie-studio/"
  # Production runs Postgres 17 (heroku pg:info, 2026-10-09); the lanes test against
  # the same major.
  POSTGRES = "#{MIRROR}postgres:17"
  IMAGE_INPUT = "postgres-image"
  # The login every service block carries: the run's own token for a ghcr.io name,
  # and nothing (the runner then skips the login) for a caller's other registry.
  CREDENTIALS = {
    "username" => "${{ startsWith(inputs.postgres-image, 'ghcr.io/') && github.actor || '' }}",
    "password" => "${{ startsWith(inputs.postgres-image, 'ghcr.io/') && github.token || '' }}"
  }.freeze

  def as_run(text = File.read(WORKFLOW)) = CiSuiteWorkflow.as_called(text)

  def services(text)
    YAML.safe_load(text).fetch("jobs").flat_map do |job, spec|
      (spec["services"] || {}).map { |name, service| ["#{job}.#{name}", service] }
    end
  end

  def service_images(text) = services(text).map { |where, service| [where, service["image"].to_s] }

  # The `<name>:<tag>` rows mirror-ci-images.yml copies, and where it copies them.
  def mirror_job = YAML.safe_load(File.read(MIRROR_WORKFLOW)).fetch("jobs").fetch("mirror")
  def mirrored = mirror_job.dig("env", "IMAGES").to_s.split

  # Every image the text names that is not a pinned mirror pull, as "where: why".
  # Reads `image:` lines and every `*-image` input default.
  def anonymous_pulls(text)
    named = text.each_line.with_index(1).filter_map do |line, number|
      (m = line.match(/^\s*image:\s*(.+?)\s*$/)) && ["line #{number}", m[1]]
    end
    named += CiSuiteWorkflow.inputs(text).select { |name, _| name.end_with?("-image") }
                            .map { |name, spec| ["input `#{name}` default", spec["default"].to_s] }
    named.filter_map do |where, image|
      next if image.match?(/\A\$\{\{\s*inputs\.[a-z-]+-image\s*\}\}\z/) # judged at its default

      why = if !image.start_with?(MIRROR) then "is an anonymous pull (bare, docker.io or another registry's name)"
            elsif image.end_with?(":latest") then "pins latest, not a major"
            elsif !image.match?(/:\d+\z/) then "carries no major tag"
            end
      "#{where}: #{image.inspect} #{why}" if why
    end
  end

  def test_every_service_container_pulls_the_pinned_image_from_the_mirror
    images = service_images(as_run)
    refute_empty images, "no service containers found; the database lanes moved and this guard must follow"
    images.each do |where, image|
      assert_equal POSTGRES, image, "#{where} pulls #{image.inspect}: every service block names the one pinned mirror image"
    end
  end

  def test_every_service_block_takes_its_image_from_the_one_input
    service_images(File.read(WORKFLOW)).each do |where, image|
      assert_equal "${{ inputs.#{IMAGE_INPUT} }}", image, "#{where} names its own image, not the `#{IMAGE_INPUT}` input"
    end
  end

  def test_every_service_block_logs_in_to_ghcr_with_the_run_token
    services(File.read(WORKFLOW)).each do |where, service|
      assert_equal CREDENTIALS, service["credentials"], "#{where} pulls without the run's ghcr.io login"
    end
  end

  def test_the_suite_token_may_read_packages
    permissions = YAML.safe_load(File.read(WORKFLOW)).fetch("permissions")
    assert_equal({ "contents" => "read", "packages" => "read" }, permissions)
  end

  def test_the_mirror_copies_the_image_the_suite_pulls_before_the_suite_needs_it
    assert_equal MIRROR.chomp("/"), mirror_job.dig("env", "TARGET")
    assert_includes mirrored, POSTGRES.delete_prefix(MIRROR), "mirror-ci-images.yml does not copy the image the lanes pull"

    doc = YAML.safe_load(File.read(MIRROR_WORKFLOW))
    assert_equal "write", doc.dig("permissions", "packages")
    on = doc.fetch(true) # YAML 1.1 reads the bare key `on` as true
    assert_includes on.dig("push", "paths"), ".github/workflows/mirror-ci-images.yml",
                    "a push that edits the mirror must run it, so a new row exists before CI pulls it"
    refute on["push"].key?("branches"), "the push trigger must fire on a feature branch, before merge"
    assert on.key?("schedule") && on.key?("workflow_dispatch")
  end

  # Satellites pull from the same mirror: turf-monster's ci.yml and devnet-nightly.yml
  # start Postgres and Redis service containers from ghcr.io/mcritchie-studio, and
  # cyvasse and moms-app pin Postgres 18. A row dropped here leaves that pull with no
  # package behind it, so every row a consumer needs is held, one by one.
  CONSUMER_ROWS = %w[postgres:17 postgres:18 redis:8].freeze

  def test_the_mirror_copies_every_row_a_consumer_pulls
    CONSUMER_ROWS.each do |row|
      assert_includes mirrored, row, "mirror-ci-images.yml no longer copies #{row}, which a consumer CI pulls"
    end
    assert mirrored.all? { |row| row.match?(/\A[a-z0-9-]+:\d+\z/) }, "every mirror row is `<name>:<major>`: #{mirrored.inspect}"
  end

  def test_no_image_anywhere_in_the_workflow_is_an_anonymous_pull
    assert_empty anonymous_pulls(File.read(WORKFLOW))
    assert_empty anonymous_pulls(as_run)
  end

  def test_control_the_guard_reads_the_image_it_asserts_against
    assert_equal POSTGRES, CiSuiteWorkflow.inputs(File.read(WORKFLOW)).dig(IMAGE_INPUT, "default")
    assert_includes as_run, "image: #{POSTGRES}"
  end

  # ---- the guard still bites when the image arrives through an input default ----

  FIXTURE = <<~YAML
    on:
      workflow_call:
        inputs:
          postgres-image:
            type: string
            default: %<default>s
    jobs:
      rails:
        runs-on: ubuntu-latest
        services:
          postgres:
            image: %<image>s
        steps: [{ run: bin/rails test }]
  YAML

  def fixture(default: POSTGRES, image: "${{ inputs.postgres-image }}") = format(FIXTURE, default: default, image: image)

  def test_unit_the_pinned_default_through_the_input_is_clean
    assert_empty anonymous_pulls(fixture)
    assert_empty anonymous_pulls(as_run(fixture))
    assert_equal [["rails.postgres", POSTGRES]], service_images(as_run(fixture))
  end

  def test_unit_a_bare_or_docker_io_input_default_is_caught
    %w[postgres postgres:17 docker.io/library/postgres:17 public.ecr.aws/docker/library/postgres:17].each do |bad|
      text = fixture(default: bad)

      assert_equal 1, anonymous_pulls(text).size, "#{bad}: the raw read sees the input default"
      assert_match(/input `postgres-image` default/, anonymous_pulls(text).first)
      assert_equal 2, anonymous_pulls(as_run(text)).size, "#{bad}: the resolved read sees the service line too"
    end
  end

  def test_unit_a_latest_or_untagged_mirror_default_is_caught
    assert_match(/pins latest/, anonymous_pulls(fixture(default: "#{MIRROR}postgres:latest")).first)
    assert_match(/no major tag/, anonymous_pulls(fixture(default: "#{MIRROR}postgres")).first)
  end

  def test_unit_a_literal_docker_hub_image_beside_the_input_is_caught
    assert_equal 1, anonymous_pulls(fixture(image: "postgres")).size
  end
end
