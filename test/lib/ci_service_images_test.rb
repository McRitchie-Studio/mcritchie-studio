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
# Run directly:
#   ruby -Itest test/lib/ci_service_images_test.rb
# Also picked up by the normal `bin/rails test` sweep.
require "minitest/autorun"
require "yaml"

class CiServiceImagesTest < Minitest::Test
  WORKFLOW = File.expand_path("../../.github/workflows/reusable-ci.yml", __dir__)
  MIRROR = "public.ecr.aws/docker/library/"
  # Production runs Postgres 17 (heroku pg:info, 2026-10-09); the lanes test against
  # the same major.
  POSTGRES = "#{MIRROR}postgres:17"

  def jobs = YAML.safe_load_file(WORKFLOW).fetch("jobs")

  def service_images
    jobs.flat_map do |job, spec|
      (spec["services"] || {}).map { |name, service| ["#{job}.#{name}", service["image"].to_s] }
    end
  end

  def test_every_service_container_pulls_the_pinned_image_from_the_mirror
    images = service_images
    refute_empty images, "no service containers found; the database lanes moved and this guard must follow"
    images.each do |where, image|
      assert_equal POSTGRES, image, "#{where} pulls #{image.inspect}: every service block names the one pinned mirror image"
    end
  end

  def test_no_image_anywhere_in_the_workflow_resolves_to_docker_hub
    File.foreach(WORKFLOW).with_index(1) do |line, number|
      next unless (m = line.match(/^\s*image:\s*(\S+)/))

      image = m[1]
      assert image.start_with?(MIRROR), "line #{number}: #{image.inspect} is a Docker Hub pull (bare or docker.io name)"
      refute_match(/:latest\z/, image, "line #{number}: pin a major, never latest")
      assert_match(/:\d+\z/, image, "line #{number}: #{image.inspect} carries no major tag")
    end
  end

  def test_control_the_guard_reads_the_image_it_asserts_against
    assert_includes File.read(WORKFLOW), "image: #{POSTGRES}"
  end
end
