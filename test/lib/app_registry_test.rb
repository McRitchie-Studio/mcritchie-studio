# frozen_string_literal: true

# [unit] The registry cross-check: config/apps.yml (AppCatalog) is the record of
# every app's identity, tier and status, and the hand-kept registries that still
# have their own readers must agree with it. config/satellites.yml (ports, navbar,
# bin/ecosystem-build), config/release_repos.yml (how each repo ships) and
# config/qa_environments.yml (QA and production targets) are each read here and
# compared row by row; any slug, port, Heroku app, status word or engine flag
# that disagrees is named in the failure.
#
# Adding an app: add its record to config/apps.yml, run this file, and fix what
# it names. Each rule below also has a test that breaks one row and expects the
# rule to name it, so a rule that stops biting fails too.

require "minitest/autorun"
require "yaml"
require_relative "../../lib/app_catalog"

class AppRegistryTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  # Ladders that keep a repo out of the conductor's sweep.
  PARKED_LADDERS = %w[dormant planned blocked].freeze
  HEROKU_REMOTE = %r{\Ahttps://git\.heroku\.com/(?<app>[^/]+)\.git\z}

  def self.load_yaml(rel) = YAML.safe_load_file(File.join(ROOT, rel))

  CATALOG = AppCatalog.parse(File.read(File.join(ROOT, "config/apps.yml")))
  SATELLITES = load_yaml("config/satellites.yml").fetch("satellites")
  RELEASE_REPOS = load_yaml("config/release_repos.yml")
  QA_ENVIRONMENTS = load_yaml("config/qa_environments.yml").fetch("qa_environments")
  WORKSPACES = load_yaml("config/workspace_icons.yml").fetch("workspaces")

  # --- the rules -------------------------------------------------------------

  def satellite_disagreements(catalog, satellites)
    errors = []
    by_slug = satellites.to_h { |row| [row["slug"], row] }
    catalog.apps.each do |app|
      next if app.port.nil? || app.slug == "mcritchie-studio" # the hub is the implicit 3000 block

      errors << "satellites.yml has no row for #{app.slug} (port #{app.port})" unless by_slug.key?(app.slug)
    end
    satellites.each do |row|
      slug = row["slug"]
      app = catalog.apps.find { |entry| entry.slug == slug }
      next errors << "satellites.yml row #{slug} is not an app in config/apps.yml" unless app

      errors << "#{slug}: port #{row['port'].inspect} in satellites.yml, #{app.port.inspect} in apps.yml" unless row["port"] == app.port
      errors << "#{slug}: name #{row['display_name'].inspect} in satellites.yml, #{app.name.inspect} in apps.yml" unless row["display_name"] == app.name
      errors << "#{slug}: emoji #{row['emoji']} in satellites.yml, #{app.emoji} in apps.yml" unless row["emoji"] == app.emoji
      errors << "#{slug}: heroku_app #{row['heroku_app'].inspect} in satellites.yml, #{app.heroku_app.inspect} in apps.yml" unless row["heroku_app"] == app.heroku_app
      errors.concat(status_disagreements(app, row["status"]))
      if row["description"].to_s.include?("no studio-engine") && app.engine
        errors << "#{slug}: satellites.yml says no studio-engine, apps.yml says engine: true"
      end
    end
    errors
  end

  # satellites.yml's status words answer a different question (is the app built
  # and linked?), so the rule is a mapping, not equality.
  def status_disagreements(app, status)
    case status
    when "active"
      app.live? ? [] : ["#{app.slug}: active in satellites.yml but #{app.status} in apps.yml"]
    when "planned"
      if app.archived? then ["#{app.slug}: planned in satellites.yml but archived in apps.yml (use reserved)"]
      elsif app.heroku_app then ["#{app.slug}: planned in satellites.yml but #{app.status} on Heroku #{app.heroku_app} (use active or reserved)"]
      else []
      end
    when "reserved" then []
    else ["#{app.slug}: satellites.yml status #{status.inspect} is not active, planned or reserved"]
    end
  end

  def release_repo_disagreements(catalog, registry)
    errors = []
    library_slugs = catalog.libraries.map(&:slug)
    registry.fetch("gems").each_key do |slug|
      errors << "release_repos.yml gem #{slug} is not a library in config/apps.yml" unless library_slugs.include?(slug)
    end
    apps = registry.fetch("apps")
    apps.each do |slug, row|
      next if library_slugs.include?(slug) # turf-vault ships as an app member but is a library

      app = catalog.apps.find { |entry| entry.slug == slug }
      next errors << "release_repos.yml app #{slug} is not an app in config/apps.yml" unless app

      ladder = row["ladder"]
      if app.live? && ladder != "three-rung"
        errors << "#{slug}: #{app.status} in apps.yml but ladder #{ladder} in release_repos.yml"
      elsif app.archived? && !PARKED_LADDERS.include?(ladder)
        errors << "#{slug}: archived in apps.yml but ladder #{ladder} in release_repos.yml (park it: #{PARKED_LADDERS.join(', ')})"
      end
      errors << "#{slug}: no repo in apps.yml but ladder #{ladder} in release_repos.yml (use planned)" if app.repo.nil? && ladder != "planned"

      deployed_to = heroku_target(row["prod_deploy"])
      if deployed_to && deployed_to != app.heroku_app
        errors << "#{slug}: release_repos.yml deploys to Heroku #{deployed_to}, apps.yml says #{app.heroku_app.inspect}"
      end
    end
    catalog.apps.each do |app|
      next unless app.live? && app.repo && !apps.key?(app.slug)

      errors << "#{app.slug}: #{app.status} with repo #{app.repo} in apps.yml but absent from release_repos.yml"
    end
    errors
  end

  def heroku_target(prod_deploy)
    return nil unless prod_deploy.is_a?(Hash)

    case prod_deploy["strategy"]
    when "git_push_heroku" then prod_deploy["remote"].to_s[HEROKU_REMOTE, :app]
    when "repo_script" then prod_deploy["heroku_app"]
    end
  end

  def qa_environment_disagreements(catalog, environments)
    errors = []
    environments.each do |slug, row|
      app = catalog.apps.find { |entry| entry.slug == slug }
      next errors << "qa_environments.yml #{slug} is not an app in config/apps.yml" unless app

      errors << "#{slug}: production_app #{row['production_app']} in qa_environments.yml, heroku_app #{app.heroku_app.inspect} in apps.yml" unless row["production_app"] == app.heroku_app
      errors << "#{slug}: qa_url #{row['qa_url']} in qa_environments.yml, #{app.qa_url.inspect} in apps.yml" unless row["qa_url"] == app.qa_url
    end
    catalog.apps.each do |app|
      errors << "#{app.slug}: apps.yml names qa_url #{app.qa_url} but qa_environments.yml has no row" if app.qa_url && !environments.key?(app.slug)
    end
    errors
  end

  def workspace_disagreements(catalog, workspaces)
    catalog.apps.filter_map do |app|
      "#{app.slug}: workspace #{app.workspace} is not in config/workspace_icons.yml" if app.workspace && !workspaces.key?(app.workspace)
    end
  end

  # --- the live files agree ----------------------------------------------------

  def test_satellites_yml_agrees_with_the_catalog
    assert_empty satellite_disagreements(CATALOG, SATELLITES)
  end

  def test_release_repos_yml_agrees_with_the_catalog
    assert_empty release_repo_disagreements(CATALOG, RELEASE_REPOS)
  end

  def test_qa_environments_yml_agrees_with_the_catalog
    assert_empty qa_environment_disagreements(CATALOG, QA_ENVIRONMENTS)
  end

  def test_every_catalog_workspace_is_a_stack_workspace
    assert_empty workspace_disagreements(CATALOG, WORKSPACES)
  end

  # --- each rule bites -----------------------------------------------------------

  def with_satellite(slug, **changes)
    SATELLITES.map { |row| row["slug"] == slug ? row.merge(changes.transform_keys(&:to_s)) : row }
  end

  def test_a_port_heroku_emoji_or_name_mismatch_is_named
    assert_includes satellite_disagreements(CATALOG, with_satellite("rolio", heroku_app: "rolio")),
                    "rolio: heroku_app \"rolio\" in satellites.yml, \"rolio-prod\" in apps.yml"
    assert_includes satellite_disagreements(CATALOG, with_satellite("turf-monster", emoji: "🏈")),
                    "turf-monster: emoji 🏈 in satellites.yml, 🐊 in apps.yml"
    assert_includes satellite_disagreements(CATALOG, with_satellite("cyvasse", port: 3700)),
                    "cyvasse: port 3700 in satellites.yml, 3600 in apps.yml"
    assert_includes satellite_disagreements(CATALOG, with_satellite("cyvasse", display_name: "Cyvase")),
                    "cyvasse: name \"Cyvase\" in satellites.yml, \"Cyvasse\" in apps.yml"
  end

  def test_status_words_map_onto_the_catalog
    assert_includes satellite_disagreements(CATALOG, with_satellite("cyvasse", status: "planned")),
                    "cyvasse: planned in satellites.yml but showcase on Heroku cyvasse (use active or reserved)"
    assert_includes satellite_disagreements(CATALOG, with_satellite("chain-ops", status: "planned")),
                    "chain-ops: planned in satellites.yml but archived in apps.yml (use reserved)"
    assert_includes satellite_disagreements(CATALOG, with_satellite("rolio", status: "active")),
                    "rolio: active in satellites.yml but archived in apps.yml"
  end

  def test_a_no_engine_description_on_an_engine_app_is_named
    rantly = with_satellite("rantly", description: "Showcase rebuild (no studio-engine, no database)")
    assert_includes satellite_disagreements(CATALOG, rantly),
                    "rantly: satellites.yml says no studio-engine, apps.yml says engine: true"
  end

  def test_a_satellite_row_or_catalog_app_alone_is_named
    stray = SATELLITES + [{ "slug" => "ghost-app", "port" => 9900 }]
    assert_includes satellite_disagreements(CATALOG, stray), "satellites.yml row ghost-app is not an app in config/apps.yml"
    missing = SATELLITES.reject { |row| row["slug"] == "moms-app" }
    assert_includes satellite_disagreements(CATALOG, missing), "satellites.yml has no row for moms-app (port 4400)"
  end

  def with_release_app(slug, row)
    RELEASE_REPOS.merge("apps" => RELEASE_REPOS.fetch("apps").merge(slug => row))
  end

  def test_release_repo_ladders_and_heroku_targets_are_named
    apps = RELEASE_REPOS.fetch("apps")
    parked_live = with_release_app("cyvasse", apps.fetch("cyvasse").merge("ladder" => "dormant"))
    assert_includes release_repo_disagreements(CATALOG, parked_live),
                    "cyvasse: showcase in apps.yml but ladder dormant in release_repos.yml"
    shipping_archived = with_release_app("rolio", apps.fetch("rolio").merge("ladder" => "three-rung"))
    assert_includes release_repo_disagreements(CATALOG, shipping_archived),
                    "rolio: archived in apps.yml but ladder three-rung in release_repos.yml (park it: dormant, planned, blocked)"
    no_repo = with_release_app("tax-studio", apps.fetch("tax-studio").merge("ladder" => "blocked"))
    assert_includes release_repo_disagreements(CATALOG, no_repo),
                    "tax-studio: no repo in apps.yml but ladder blocked in release_repos.yml (use planned)"
    wrong_app = with_release_app("rantly", apps.fetch("rantly").merge(
      "prod_deploy" => { "strategy" => "git_push_heroku", "remote" => "https://git.heroku.com/rantly.git" }))
    assert_includes release_repo_disagreements(CATALOG, wrong_app),
                    "rantly: release_repos.yml deploys to Heroku rantly, apps.yml says \"mcr-rantly\""
  end

  def test_a_live_app_missing_from_release_repos_is_named
    registry = RELEASE_REPOS.merge("apps" => RELEASE_REPOS.fetch("apps").except("moms-app"))
    assert_includes release_repo_disagreements(CATALOG, registry),
                    "moms-app: active with repo McRitchie-Studio/moms-app in apps.yml but absent from release_repos.yml"
  end

  def test_qa_environment_mismatches_are_named
    rolio = QA_ENVIRONMENTS.merge("rolio" => QA_ENVIRONMENTS.fetch("rolio").merge("production_app" => "rolio"))
    assert_includes qa_environment_disagreements(CATALOG, rolio),
                    "rolio: production_app rolio in qa_environments.yml, heroku_app \"rolio-prod\" in apps.yml"
    assert_includes qa_environment_disagreements(CATALOG, QA_ENVIRONMENTS.except("turf-monster")),
                    "turf-monster: apps.yml names qa_url https://qa.turfmonster.media but qa_environments.yml has no row"
  end
end
