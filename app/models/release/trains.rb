# frozen_string_literal: true

require "yaml"

class Release
  # Release::Trains — which release train a task rides (release-trains-design.md §2,
  # task B). A thin reader over config/release_trains.yml plus the one routing rule.
  #
  # The HUB train is implicit: config/release_trains.yml lists only the per-app trains,
  # and every task that does not route to one of them rides "hub". A task routes to a
  # listed train only when EVERY repo it names belongs to that train, so a task naming
  # a gem, the hub, or two apps rides the hub, where gems publish producer-first.
  #
  # Rails-free and IO-light on purpose, like Release::SweepPlan and Release::Ladder:
  # bin/release `require_relative`s it and judges a candidate's train from its OWN copy
  # of the config, so the CLI holds an off-train task even against a deployed board
  # that predates trains. Every pure method takes the config as an argument; `config`
  # only loads the file.
  module Trains
    # Mirrors Release::DEFAULT_TRAIN. Kept here as well because bin/release loads this
    # file without the ActiveRecord model; release_trains_test pins the two together.
    HUB = "hub"
    FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    CONFIG_PATH = File.expand_path("../../../config/release_trains.yml", __dir__)

    module_function

    # { "<train>" => { "repos" => [repo, ...] } } for every LISTED train, memoized for
    # the process. A missing or empty file is no per-app trains at all: everything
    # rides the hub, which is the behaviour before trains existed.
    def config
      @config ||= load_file(CONFIG_PATH)
    end

    def reload!
      @config = nil
      config
    end

    # THE TEST SEAM: run the block with `trains` (the normalized shape) as the config,
    # then restore whatever was loaded. config/release_trains.yml lists no train until
    # task C, so a test of the routing names the trains it routes to.
    def with_config(trains)
      saved = @config
      @config = normalize(trains)
      yield
    ensure
      @config = saved
    end

    # Parse a trains file into the normalized shape. Raises on a malformed entry
    # rather than routing around it: a train config nobody can read must not quietly
    # send an app's tasks to the hub.
    def load_file(path)
      return {} unless File.exist?(path)

      normalize(YAML.safe_load_file(path) || {})
    end

    def normalize(raw)
      raise ArgumentError, "release trains config must be a mapping" unless raw.is_a?(Hash)

      raw.to_h do |train, entry|
        name = train.to_s.strip
        raise ArgumentError, "release train #{name.inspect} is not a kebab-case slug" unless FORMAT.match?(name)
        raise ArgumentError, "the hub train is implicit; do not list #{HUB.inspect}" if name == HUB

        repos = Array((entry || {})["repos"]).map { |repo| repo.to_s.strip }.reject(&:empty?).uniq
        raise ArgumentError, "release train #{name} lists no repos" if repos.empty?

        [ name, { "repos" => repos } ]
      end
    end

    # Every train a release can ride: the hub first, then each listed train.
    def names(trains = config)
      [ HUB ] + trains.keys
    end

    def known?(train, trains = config)
      names(trains).include?(train.to_s)
    end

    # The repos a LISTED train owns; [] for the hub, which owns no repo exclusively.
    def repos_for(train, trains = config)
      trains.dig(train.to_s, "repos") || []
    end

    # The train a task naming `repos` rides. A listed train only when every repo
    # belongs to it; anything else (no repos, a gem, a second app, the hub) is HUB.
    def train_for(repos, trains = config)
      named = Array(repos).map { |repo| repo.to_s.strip }.reject(&:empty?).uniq
      return HUB if named.empty?

      trains.each do |train, entry|
        return train if (named - entry["repos"]).empty?
      end
      HUB
    end

    # THE APP TRAIN'S ACCEPTED GUARD (release-trains-design.md §2): the promote moves
    # ALL of a repo's `accepted`, so an app train must not promote a repo whose
    # `accepted` carries a commit from a task that rides ANOTHER train — typically an
    # app-plus-engine task, whose app half would ship before the hub publishes its gem.
    #
    #   stranded   — { repo => [{ "sha", "subject" }] }, the commits `accepted` is
    #                ahead of `release` by (bin/release reads them from git).
    #   task_repos — { slug => [repo, ...] } for the task slugs the merge subjects
    #                name (Release::MergeSubject), read from the board.
    #
    # Returns one { "repo", "sha", "subject", "slug", "train" } per commit whose task
    # rides a train other than `train`. A commit no task can be read for (a feature
    # commit under its merge, a rung merge, a slug the board does not know) is not
    # attributable and not reported: the guard narrows to work it can name.
    def foreign_accepted_work(stranded, task_repos, train, trains = config)
      Hash(stranded).flat_map do |repo, commits|
        Array(commits).filter_map do |commit|
          subject = (commit["subject"] || commit[:subject]).to_s
          slug = Release::MergeSubject.slug_from_subject(subject)
          next unless slug && task_repos.key?(slug)

          rides = train_for(task_repos[slug], trains)
          next if rides == train.to_s

          { "repo" => repo.to_s, "sha" => (commit["sha"] || commit[:sha]).to_s, "subject" => subject,
            "slug" => slug, "train" => rides }
        end
      end
    end

    # Parse `--train <slug>` (or `--train=<slug>`) out of argv, deleting it. Returns
    # [train, error]: the hub when the flag is absent, an error string when it is
    # present but empty or names no known train. Refusing here is the point: a bare
    # `--train` that silently fell back to the hub would sweep the hub's queue.
    def take_flag(argv, trains = config)
      index = argv.index { |arg| arg.to_s == "--train" || arg.to_s.start_with?("--train=") }
      return [ HUB, nil ] unless index

      token = argv.delete_at(index).to_s
      value = token == "--train" ? argv.delete_at(index).to_s : token.split("=", 2).last.to_s
      value = value.strip
      return [ nil, "--train needs a train slug (one of: #{names(trains).join(', ')})" ] if value.empty? || value.start_with?("-")
      return [ nil, "unknown release train #{value.inspect} (one of: #{names(trains).join(', ')})" ] unless known?(value, trains)

      [ value, nil ]
    end
  end
end
