# frozen_string_literal: true

# Guard: NO CI STEP FETCHES FROM AN APT MIRROR. The lanes that need packages run
# inside the lane image (.github/ci-image/Dockerfile, built weekly by
# mirror-ci-images.yml). The apt mirror stall was the top red-then-green cause
# (refactor-review-2026-11-06, lane-health 2f), and a red a re-run turns green is a
# defect with a cause, not a retry (Alex McRitchie, 2026-11-06). Replaced
# test/lib/ci_apt_step_timeout_test.rb. Task: deterministic-ci.
require "minitest/autorun"
require "yaml"

class CiLaneImageTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOWS = Dir[File.join(ROOT, ".github/workflows/*.yml")].sort
  REUSABLE = File.join(ROOT, ".github/workflows/reusable-ci.yml")
  MIRROR = File.join(ROOT, ".github/workflows/mirror-ci-images.yml")
  DOCKERFILE = File.join(ROOT, ".github/ci-image/Dockerfile")
  LANE_IMAGE_EXPR = "${{ inputs.lane-image }}"
  IMAGE_LANES = %w[island_animator playwright rails system].freeze
  # No job is excepted. `system` was the last bare-runner lane with an apt step; it moved
  # into the image after the mirror went unresolvable on 2026-11-11 (task
  # ci-system-lane-in-image). An entry here is a lane that can go red on a mirror.
  APT_EXCEPTIONS = {}.freeze

  # What the lanes installed with apt before they moved into the image. Each must be
  # in the image, or the lane that needed it now fails at a missing binary.
  LANE_PACKAGES = %w[curl ffmpeg imagemagick libjemalloc2 libpq-dev librsvg2-bin libvips postgresql-client].freeze

  # A step that can fetch from apt: a direct apt/apt-get install or update (continuation
  # lines joined), and `playwright install --with-deps`, which runs apt-get underneath.
  def self.apt_fetch?(run)
    r = run.to_s.gsub(/\\\n\s*/, " ")
    r.include?("--with-deps") || r.include?("apt-retry") ||
      r.match?(/\bapt(?:-get)?\b[^\n]*\b(?:install|update|upgrade|dist-upgrade)\b/)
  end

  def load(path) = YAML.load_file(path, aliases: true) || {}

  def jobs(path) = load(path)["jobs"] || {}

  def reusable_inputs = load(REUSABLE).dig(true, "workflow_call", "inputs") || load(REUSABLE).dig("on", "workflow_call", "inputs")

  def dockerfile_packages
    text = File.read(DOCKERFILE).gsub(/\\\n/, " ")
    install = text.lines.grep(/apt-get install/).join(" ")
    install.split.reject { |w| w.start_with?("-") || w.include?("&&") }
  end

  def test_no_workflow_step_fetches_from_apt
    refute_empty WORKFLOWS
    offenders = WORKFLOWS.flat_map do |path|
      jobs(path).reject { |name, _| APT_EXCEPTIONS.fetch(File.basename(path), []).include?(name) }.flat_map do |name, job|
        Array(job["steps"]).select { |step| self.class.apt_fetch?(step["run"]) }
                           .map { |step| "#{File.basename(path)} #{name}: #{step['name'] || step['run'].to_s[0, 60]}" }
      end
    end
    assert_empty offenders, "these steps fetch from an apt mirror; put the package in .github/ci-image/Dockerfile instead"
  end

  # The guard the 2026-11-11 outage asked for: no job in reusable-ci.yml runs apt on the
  # bare runner, and the file names no apt-get or apt-retry at all, so an apt step cannot
  # come back in a form the step classifier misses (an `if:`-gated step, a composite).
  def test_no_reusable_job_runs_apt_on_the_bare_runner
    offenders = jobs(REUSABLE).reject { |_, job| job["container"] }.flat_map do |name, job|
      Array(job["steps"]).select { |s| self.class.apt_fetch?(s["run"]) || s.dig("with", "install-dependencies") == true }
                         .map { |s| "#{name}: #{s['name']}" }
    end
    assert_empty offenders, "these bare-runner steps fetch from an apt mirror; run the job in inputs.lane-image"
    text = File.read(REUSABLE)
    refute_match(/^\s*[^#\n]*\bapt-get\b/, text, "reusable-ci.yml runs apt-get")
    refute_match(/^\s*[^#\n]*apt-retry/, text, "reusable-ci.yml calls apt-retry")
  end

  def test_no_ci_error_text_tells_anyone_to_rerun
    texts = WORKFLOWS + Dir[File.join(ROOT, ".github/scripts/*")]
    offenders = texts.select { |path| File.read(path).match?(/::error::[^\n]*re-?run (this|the) job/i) }
    assert_empty offenders, "a red has a cause; error text names it instead of asking for a re-run"
  end

  def test_setup_chrome_installs_no_apt_dependencies
    WORKFLOWS.each do |path|
      jobs(path).each do |name, job|
        next if APT_EXCEPTIONS.fetch(File.basename(path), []).include?(name)

        Array(job["steps"]).select { |s| s["uses"].to_s.start_with?("browser-actions/setup-chrome") }.each do |step|
          assert_equal false, step.dig("with", "install-dependencies"), "#{name}: setup-chrome's install-dependencies runs apt"
        end
      end
    end
  end

  def test_the_apt_lanes_run_in_the_lane_image
    all = jobs(REUSABLE)
    IMAGE_LANES.each do |lane|
      container = all.fetch(lane).fetch("container") { flunk "#{lane} runs on the bare runner" }
      assert_equal LANE_IMAGE_EXPR, container["image"], "#{lane} must run in the lane-image input"
      assert_equal "${{ github.token }}", container.dig("credentials", "password"), "#{lane} pulls ghcr.io with the run token"
      assert_includes container["options"].to_s, "--init", "#{lane} needs a PID 1 that reaps killed children"
    end
  end

  def test_lane_image_default_is_the_image_the_mirror_builds
    default = reusable_inputs.fetch("lane-image").fetch("default")
    built = jobs(MIRROR).fetch("lane-image").dig("env", "IMAGE")
    assert_equal built, default
    lane = load(REUSABLE).fetch("jobs").fetch("system")
    assert_equal({ "contents" => "read", "packages" => "read" }, lane["permissions"], "the lane pulls the image with the run's token")
  end

  def test_the_image_builds_on_the_mirrored_base
    base = File.read(DOCKERFILE)[/^ARG BASE=(\S+)/, 1]
    mirrored = jobs(MIRROR).fetch("mirror").dig("env", "IMAGES").split.map { |i| "ghcr.io/mcritchie-studio/#{i}" }
    assert_includes mirrored, base, "the Dockerfile's base must be a row the mirror copies to ghcr.io"
    assert_equal ["mirror"], Array(jobs(MIRROR).fetch("lane-image")["needs"])
  end

  def test_the_image_carries_every_lane_package_and_the_system_default
    have = dockerfile_packages
    wanted = LANE_PACKAGES + reusable_inputs.fetch("system-packages").fetch("default").split
    assert_empty wanted.uniq - have, "the lane image lacks these packages"
  end

  # Inside a container job the Postgres service is reached by its label, and
  # `${{ github.workspace }}` names the HOST path, which the container cannot see.
  def test_container_lanes_reach_postgres_by_label_and_use_workspace_relative_paths
    IMAGE_LANES.each do |lane|
      text = jobs(REUSABLE).fetch(lane).to_yaml
      refute_match %r{postgres@localhost}, text, lane
      refute_includes text, "${{ github.workspace }}", lane
    end
  end

  def test_the_classifier_sees_each_apt_spelling
    assert self.class.apt_fetch?("sudo apt-get update")
    assert self.class.apt_fetch?("sudo apt-get install \\\n  -y ffmpeg")
    assert self.class.apt_fetch?("npx playwright install --with-deps chromium")
    refute self.class.apt_fetch?("npx playwright install chromium")
    refute self.class.apt_fetch?("dpkg-query -W libvips")
  end
end
