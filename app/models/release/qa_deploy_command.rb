# frozen_string_literal: true

class Release
  # The `bin/qa-server deploy` command line, in ONE place — IO-free and Rails-free
  # (bin/release `require_relative`s this file directly, so it must load
  # standalone).
  #
  # WHY A MODULE FOR ONE STRING. bin/release printed this command TWICE and the two
  # copies drifted. The one it RUNS carried `--yes`; the one it hands the operator
  # as a REMEDY did not:
  #
  #   step("qa deploy: bin/qa-server deploy #{app} origin/release --yes")   # runs
  #   say("… QA deploy FAILED, retry `bin/qa-server deploy #{app} origin/release`")  # printed
  #
  # bin/qa-server's confirmation gate is deliberate and good — `run_deploy` aborts
  # with "QA deploy is an external write. Re-run with --yes after reviewing" — so
  # the printed remedy was a command that CANNOT RUN. Measured twice on 2026-09-22:
  # both times the operator copied the line, hit the gate, and had to discover the
  # flag. A remedy that does not run is worse than no remedy, because it spends the
  # reader's attention before it spends their time.
  #
  # Deleting one copy is not the fix — a second caller would re-introduce it. There
  # is now ONE producer, both sites call it, and the test asserts what it emits
  # satisfies the flag bin/qa-server's own abort demands (read out of bin/qa-server,
  # not restated here, so moving that gate reds this rather than drifting past it).
  module QaDeployCommand
    # The flag bin/qa-server's external-write confirmation requires. Named here for
    # ONE reason: so the test can compare it against bin/qa-server's own sentence.
    CONFIRM_FLAG = "--yes"

    module_function

    # The script, relative to a hub checkout's root.
    SCRIPT = "bin/qa-server"

    # `qa_app` is the registry slug bin/qa-server takes (not the Heroku app name),
    # and `branch` the release branch whose origin ref gets deployed.
    #
    # `hub_root:` names the hub checkout the script lives in. bin/release passes its
    # own (File.expand_path("..", __dir__)) so the command it RUNS and the remedy it
    # PRINTS work from any cwd. Without it the script path is relative, and a
    # prepare run from /Users/alex/projects failed every QA deploy with ENOENT
    # ("could not run bin/qa-server: No such file or directory", rel-20261110-208612).
    def for(qa_app:, branch:, hub_root: nil)
      argv(qa_app: qa_app, branch: branch, hub_root: hub_root).join(" ")
    end

    # The same command as an argv, for the spawn.
    def argv(qa_app:, branch:, hub_root: nil)
      script = hub_root.to_s.empty? ? SCRIPT : File.join(hub_root.to_s, SCRIPT)
      [script, "deploy", qa_app.to_s, "origin/#{branch}", CONFIRM_FLAG]
    end
  end
end
