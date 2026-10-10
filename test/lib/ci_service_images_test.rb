# frozen_string_literal: true
# Guard test for the service containers in .github/workflows/reusable-ci.yml: the
# image every database lane pulls, and where it pulls it from.
#
# Why this test exists: `image: postgres` resolves to Docker Hub, and Docker Hub
# meters anonymous pulls per IP. GitHub's hosted runners share their IPs, so on a
# busy afternoon every lane with a database dies at setup with `toomanyrequests`
# before a single test runs (three consecutive runs on 2026-10-09). ECR Public
# mirrors the official library with no anonymous limit and no credential. A bare
# image name, a Docker Hub name, or a drift between the three service blocks puts
# the quota back on the critical path, so this asserts the name directly.
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
  MIRROR = "public.ecr.aws/docker/library/"
  # Production runs Postgres 17 (heroku pg:info, 2026-10-09); the lanes test against
  # the same major.
  POSTGRES = "#{MIRROR}postgres:17"
  IMAGE_INPUT = "postgres-image"

  def as_run(text = File.read(WORKFLOW)) = CiSuiteWorkflow.as_called(text)

  def service_images(text)
    YAML.safe_load(text).fetch("jobs").flat_map do |job, spec|
      (spec["services"] || {}).map { |name, service| ["#{job}.#{name}", service["image"].to_s] }
    end
  end

  # Every image the text names that is not a pinned mirror pull, as "where: why".
  # Reads `image:` lines and every `*-image` input default.
  def docker_hub_pulls(text)
    named = text.each_line.with_index(1).filter_map do |line, number|
      (m = line.match(/^\s*image:\s*(.+?)\s*$/)) && ["line #{number}", m[1]]
    end
    named += CiSuiteWorkflow.inputs(text).select { |name, _| name.end_with?("-image") }
                            .map { |name, spec| ["input `#{name}` default", spec["default"].to_s] }
    named.filter_map do |where, image|
      next if image.match?(/\A\$\{\{\s*inputs\.[a-z-]+-image\s*\}\}\z/) # judged at its default

      why = if !image.start_with?(MIRROR) then "is a Docker Hub pull (bare or docker.io name)"
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

  def test_no_image_anywhere_in_the_workflow_resolves_to_docker_hub
    assert_empty docker_hub_pulls(File.read(WORKFLOW))
    assert_empty docker_hub_pulls(as_run)
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
    assert_empty docker_hub_pulls(fixture)
    assert_empty docker_hub_pulls(as_run(fixture))
    assert_equal [["rails.postgres", POSTGRES]], service_images(as_run(fixture))
  end

  def test_unit_a_bare_or_docker_io_input_default_is_caught
    %w[postgres postgres:17 docker.io/library/postgres:17].each do |bad|
      text = fixture(default: bad)

      assert_equal 1, docker_hub_pulls(text).size, "#{bad}: the raw read sees the input default"
      assert_match(/input `postgres-image` default/, docker_hub_pulls(text).first)
      assert_equal 2, docker_hub_pulls(as_run(text)).size, "#{bad}: the resolved read sees the service line too"
    end
  end

  def test_unit_a_latest_or_untagged_mirror_default_is_caught
    assert_match(/pins latest/, docker_hub_pulls(fixture(default: "#{MIRROR}postgres:latest")).first)
    assert_match(/no major tag/, docker_hub_pulls(fixture(default: "#{MIRROR}postgres")).first)
  end

  def test_unit_a_literal_docker_hub_image_beside_the_input_is_caught
    assert_equal 1, docker_hub_pulls(fixture(image: "postgres")).size
  end
end
