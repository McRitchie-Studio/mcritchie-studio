# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

# [integration] The desk database guard's INITIALIZER refuses a development boot in a
# scratch worktree (/tasks/harden-scratch-worktree-recipes).
#
#   bin/rails test test/integration/desk_database_guard_scratch_worktree_test.rb
#
# THE HOLE. Reviewer, zap and arbitration throwaways are cut at `$(mktemp -d)/<name>`,
# outside `.worktrees/`, where DeskDatabaseGuard's desk-path match never fired, so a bare
# development-env `bin/rails runner` or `db:migrate` in one reached the shared
# mcritchie_studio_development. test/lib/desk_database_guard_test.rb pins the pure rule;
# this pins the WIRING: config/initializers/desk_database_guard.rb, run from a real
# `git worktree add` target outside any `.worktrees/`, must hand the rule the
# linked-worktree fact and abort.
#
# NOTHING HERE BOOTS A DEVELOPMENT APP OR TOUCHES A DATABASE. The guard and its
# initializer are copied into a throwaway `git init`, a scratch worktree is cut from it,
# and the initializer is loaded in a child ruby under a stand-in `Rails` that answers only
# the four things the initializer reads.
class DeskDatabaseGuardScratchWorktreeTest < ActiveSupport::TestCase
  FILES = %w[lib/desk_database_guard.rb config/initializers/desk_database_guard.rb].freeze
  SHARED = "mcritchie_studio_development"

  # The child: a minimal Rails, then the initializer exactly as it ships. `abort` exits 1
  # with the refusal on stderr; a pass exits 0.
  RUNNER = <<~RUBY
    require "pathname"
    module Rails
      Env = Struct.new(:name) do
        def development? = name == "development"
        def to_s = name
      end
      Config = Struct.new(:database_configuration)
      App = Struct.new(:config)
      def self.root = Pathname.new(Dir.pwd)
      def self.env = Env.new(ENV.fetch("FAKE_RAILS_ENV"))
      def self.application = App.new(Config.new({ "development" => { "database" => "#{SHARED}" } }))
    end
    load File.join(Dir.pwd, "config/initializers/desk_database_guard.rb")
    puts "booted"
  RUBY

  def setup
    @sandbox = Dir.mktmpdir("desk-db-guard-scratch")
    @primary = File.join(@sandbox, "mcritchie-studio")
    @scratch = File.join(@sandbox, "scratchpad", "zap-some-task") # NOT under .worktrees/

    FILES.each do |rel|
      FileUtils.mkdir_p(File.dirname(File.join(@primary, rel)))
      FileUtils.cp(Rails.root.join(rel), File.join(@primary, rel))
    end
    git!(@sandbox, "init", "--quiet", "--initial-branch=main", @primary)
    git!(@primary, "add", "--all")
    git!(@primary, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
         "commit", "--quiet", "--message", "seed")
    git!(@primary, "worktree", "add", "--quiet", "--detach", @scratch, "HEAD")
  end

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  test "a development boot in a scratch worktree outside .worktrees/ is refused" do
    out, err, status = boot(@scratch, "development")

    refute_predicate status, :success?,
                     "the initializer let a development boot in a scratch worktree reach the shared DB " \
                     "(stdout=#{out.inspect})"
    assert_includes err, "refusing to run against the SHARED development database (#{SHARED})"
    assert_includes err, "RAILS_ENV=test", "the refusal names the recipe's own escape"
  end

  test "the primary checkout, a test boot, and the override all still pass" do
    assert_booted boot(@primary, "development"), "the primary checkout is never refused"
    assert_booted boot(@scratch, "test"), "RAILS_ENV=test in a scratch worktree is the recipe's path"
    assert_booted boot(@scratch, "development", "ALLOW_SHARED_DEV_DB" => "1"), "the override still overrides"
    assert_booted boot(@scratch, "development", "DATABASE_URL" => "postgresql://localhost/own_db"),
                  "a scratch worktree pointed at its own DB is not on the shared one"
  end

  private

  def boot(dir, rails_env, extra = {})
    env = { "FAKE_RAILS_ENV" => rails_env, "DATABASE_URL" => nil, "ALLOW_SHARED_DEV_DB" => nil,
            "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil }.merge(extra)
    Open3.capture3(env, RbConfig.ruby, "-e", RUNNER, chdir: dir)
  end

  def assert_booted(result, message)
    out, err, status = result
    assert_predicate status, :success?, "#{message} (stderr=#{err.inspect})"
    assert_includes out, "booted"
  end

  def git!(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end
end
