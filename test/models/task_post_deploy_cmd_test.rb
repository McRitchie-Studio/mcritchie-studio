# frozen_string_literal: true

require "test_helper"

# Guard catalog row 2.8: a bare full-suite seed post_deploy_cmd is refused when the
# task is WRITTEN, so bin/dor-check never meets one. bin/release runs the command
# verbatim against production, and `db:seed` loads every db/seeds/*.rb.
class TaskPostDeployCmdTest < ActiveSupport::TestCase
  REJECTED = [
    "bin/rails db:seed",
    "rails db:seed",
    "bundle exec rails db:seed",
    "bin/rails db:seed:replant",
    "rake db:seed",
    "bundle exec rails db:seed RAILS_ENV=production"
  ].freeze

  ACCEPTED = [
    "rails runner 'load Rails.root.join(\"db/seeds/54_demo.rb\").to_s'",
    "bin/rails pokemon:seed",
    "bin/rails pokemon:resync_mascots",
    "bin/rails db:migrate",
    "none"
  ].freeze

  def build_task(cmd)
    Task.new(title: "Post Deploy Command Check", stage: "designed",
             metadata: { "devops" => { "post_deploy_cmd" => cmd } })
  end

  test "a bare full-suite seed command is refused on write" do
    REJECTED.each do |cmd|
      task = build_task(cmd)

      refute task.valid?, "expected #{cmd.inspect} to be refused"
      assert(task.errors[:base].any? { |e| e.include?("bare full-suite seed") }, cmd)
    end
  end

  test "a narrow command saves" do
    ACCEPTED.each do |cmd|
      task = build_task(cmd)
      task.valid?

      refute(task.errors[:base].any? { |e| e.include?("bare full-suite seed") }, cmd)
    end
  end

  test "a legacy row holding a bare seed still saves when the command is untouched" do
    task = build_task("bin/rails pokemon:seed")
    task.save!
    task.update_columns(metadata: { "devops" => { "post_deploy_cmd" => "bin/rails db:seed" } })
    task.reload

    task.title = "Post Deploy Command Renamed"
    assert task.valid?, task.errors.full_messages.inspect
  end
end
