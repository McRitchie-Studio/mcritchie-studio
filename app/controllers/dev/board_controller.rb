# frozen_string_literal: true

module Dev
  # Local-only board toys: spawn / advance / remove a throwaway "dev fixture" task
  # so the live /deployments board (Turbo Streams) can be demoed without real data
  # or admin-auth gymnastics. NEVER mounted in production — the routes draw only
  # when Rails.env.local? (development + test), and every action re-checks the env
  # as defense in depth. Mutations are scoped to fixtures (metadata.dev_fixture),
  # so a real task is never touched.
  class BoardController < ApplicationController
    # A local-only convenience tool — no login required (the value is skipping
    # auth gymnastics). Safe because it is gated to Rails.env.local? at both the
    # route and the action. CSRF still applies in the browser (the buttons send
    # the token); it's off in the test env as usual.
    skip_before_action :require_authentication, raise: false
    before_action :ensure_local!

    FIXTURE_MARK = "dev_fixture"
    # Whimsical titles so a spawned card reads like a real one on the board.
    SAMPLE_TITLES = [
      "Refactor the flux capacitor", "Polish the warp nacelles", "Untangle the spaghetti",
      "Feed the CI hamsters", "Rename all the things", "Debounce the kraken",
      "Caffeinate the scheduler", "Yak-shave the build pipeline"
    ].freeze

    # Spawn a fresh fixture in Designed → after_create genesis TaskEvent → the
    # broadcaster prepends the card to the Designed column live (no reload).
    def generate
      mascot = Pokemon.draw # a random mon, so the card wears a real type color
      Task.create!(
        title: SAMPLE_TITLES.sample,
        slug: "dev-fixture-#{SecureRandom.hex(3)}", # explicit + unique: sample titles repeat
        stage: "designed",
        metadata: {
          FIXTURE_MARK => true,
          "devops" => { "repositories" => ["mcritchie-studio"], "mascot" => mascot&.slug }.compact
        }
      )
      # The client tints the spawn glow with the mascot's primary type color.
      render json: { color: mascot&.signature_color }
    end

    # Advance the newest fixture one deploy-stage (wrapping shipped → designed) →
    # after_update transition TaskEvent → the broadcaster moves the card live.
    def move
      task = latest_fixture or return head(:no_content)
      task.update!(stage: next_stage(task.stage))
      render json: { color: fixture_color(task) }
    end

    # Drop the newest fixture. A destroy fires no TaskEvent, so broadcast the Turbo
    # Stream remove explicitly (guarded so a dead cable can't break the request).
    def delete
      task = latest_fixture or return head(:no_content)
      slug = task.slug
      task.destroy!
      Studio::Cable.safe_broadcast do
        Turbo::StreamsChannel.broadcast_remove_to(DeploymentsBroadcaster::STREAM, target: "card-#{slug}")
      end
      head :no_content
    end

    private

    def ensure_local!
      head :forbidden unless Rails.env.local?
    end

    # Newest dev fixture, or nil. Scoped to the marker so move/delete can NEVER
    # touch a real task.
    def latest_fixture
      Task.where("metadata ->> ? = 'true'", FIXTURE_MARK).order(created_at: :desc).first
    end

    def next_stage(stage)
      zones = Task::DEPLOYMENTS_BOARD_STAGES
      zones[((zones.index(stage) || -1) + 1) % zones.size]
    end

    # The primary (signature) type color of a fixture's mascot, for the spawn glow.
    def fixture_color(task)
      Pokemon.find_by(slug: task.devops_field("mascot").to_s.presence)&.signature_color
    end
  end
end
