class Release
  # Pure decision logic for the release pipeline's post-deploy command hook —
  # the seam behind `bin/release prepare`/`ship` that runs a release member's
  # declared `devops.post_deploy_cmd` against the just-deployed app (the QA heroku
  # app on prepare, the production app on ship).
  #
  # Like Release::ShipSequence + Release::GemfileRepin this is deliberately IO-free:
  # no heroku, no git, no network. It takes the repo plan + the qa_environments
  # registry in and returns an ordered list of { task, repo, app, cmd } commands
  # out, so the `heroku run` orchestration + the abort-on-failure + the
  # checks_run recording all stay in bin/release and the target-resolution +
  # filtering decisions stay HERE, unit tested. (bin/release `require`s this file
  # directly — it has no Rails deps.)
  #
  # WHY a member declares this: a deploy sometimes needs a one-off command run on
  # the dyno AFTER the code is live (a backfill, a cache warm, a data migration).
  # Before this hook those lived only in PR prose (e.g. backfill-pokemon-mascots's
  # `heroku run rake pokemon:backfill_mascots`) and had to be run by hand on QA and
  # again on prod. Declaring it on the task makes the pipeline run it on both,
  # record the outcome, and abort the release if it fails.
  module PostDeploy
    module_function

    # The two pipeline targets a post-deploy command can run against: :qa (the
    # repo's QA heroku app, run during `prepare`) and :prod (its production app,
    # run during `ship`).
    TARGETS = %i[qa prod].freeze

    # Build the ordered post-deploy command plan for a release.
    #
    # `repos`           — the repo_plan output as the CLI sees it (JSON-parsed →
    #                     STRING keys). Each group carries "repo", "qa_app" (the
    #                     qa-server key), and "members" (each member may carry a
    #                     non-blank "post_deploy_cmd").
    # `qa_environments` — config/qa_environments.yml's "qa_environments" map
    #                     (qa-server key → { "heroku_app", "production_app", … }).
    # `target`          — :qa (run on the QA heroku app) or :prod (run on prod).
    #
    # Returns one entry PER member that declares a non-blank post_deploy_cmd, in
    # plan (producer-first) order:
    #   { "task" => slug, "repo" => repo, "app" => heroku-app, "cmd" => command }
    # `app` is "" when the repo has no registered target for `target` — the CLI
    # treats a blank app as a hard abort (a declared command with nowhere to run),
    # so a misdeclared command never silently no-ops.
    def plan(repos, qa_environments:, target:)
      raise ArgumentError, "target must be one of #{TARGETS.inspect}, got #{target.inspect}" unless TARGETS.include?(target)

      Array(repos).flat_map do |group|
        app = target_app(qa_environments, group["qa_app"], target)
        Array(group["members"]).filter_map do |member|
          cmd = member["post_deploy_cmd"].to_s.strip
          next if cmd.empty?

          { "task" => member["slug"].to_s, "repo" => group["repo"].to_s,
            "app" => app, "cmd" => cmd }
        end
      end
    end

    # The heroku app a post-deploy command runs on for `target`, resolved from the
    # qa_environments registry by qa-server key: :qa → "heroku_app" (the QA app),
    # :prod → "production_app". "" when the key isn't registered (a gem group, or
    # an app with no QA env) — the caller aborts on a declared-but-unroutable cmd.
    def target_app(qa_environments, qa_app, target)
      env = (qa_environments || {}).fetch(qa_app.to_s, nil) || {}
      (target == :qa ? env["heroku_app"] : env["production_app"]).to_s
    end
  end
end
