# frozen_string_literal: true

# [unit] AgentMailbox::LaunchAgent — `bin/dispatcher install|uninstall|status`.
# The plist template renders with this machine's paths, install writes it into a
# THROWAWAY home and bootstraps it, uninstall removes it, status reads launchctl.
# launchctl is a recording stub: nothing here loads a real service.
#   ruby -Itest test/lib/agent_dispatcher_launch_agent_test.rb
require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/agent_dispatcher"

class AgentDispatcherLaunchAgentTest < Minitest::Test
  Status = Struct.new(:ok) do
    def success? = ok
  end

  def setup
    @home = Dir.mktmpdir("dispatcher-home")
    @calls = []
    @print = "state = running\n\tpid = 4242\n\tlast exit code = (never exited)\n"
    # A stateful launchctl: bootout unloads the label at once (or after
    # @linger more prints), bootstrap loads it unless @bootstrap_failures says
    # otherwise, and print answers only while it is loaded.
    @loaded = false
    @linger = 0
    @bootstrap_failures = 0
    @sleeps = []
    @launchctl = lambda do |*args|
      @calls << args
      case args.first
      when "bootout" then @unloading = true
                          [ "", Status.new(true) ]
      when "print"
        if @unloading && @linger.positive?
          @linger -= 1
          next [ @print, Status.new(true) ]
        end
        @loaded = false if @unloading
        @unloading = false
        @loaded ? [ @print, Status.new(true) ] : [ "Could not find service", Status.new(false) ]
      when "bootstrap"
        if @bootstrap_failures.positive?
          @bootstrap_failures -= 1
          next [ "Bootstrap failed: 5: Input/output error", Status.new(false) ]
        end
        @loaded = true
        [ "", Status.new(true) ]
      else [ "", Status.new(true) ]
      end
    end
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(@home)

  def agent(**opts)
    AgentMailbox::LaunchAgent.new(**{ home: @home, repo_root: "/repo & co", ruby: "/opt/ruby/bin/ruby", path: "/usr/bin",
                                      uid: 501, launchctl: @launchctl, out: @out,
                                      sleeper: ->(sec) { @sleeps << sec } }.merge(opts))
  end

  def test_render_fills_every_placeholder_and_escapes_xml
    xml = agent.render

    refute_match(/\{\{/, xml)
    assert_includes xml, "<string>/opt/ruby/bin/ruby</string>"
    assert_includes xml, "<string>/repo &amp; co/bin/dispatcher</string>"
    assert_includes xml, "<string>#{@home}/Library/Logs/agent-dispatcher.log</string>"
    assert_includes xml, "<key>KeepAlive</key>\n  <true/>"
    assert_includes xml, "<key>RunAtLoad</key>\n  <true/>"
    assert_includes xml, "#{@home}/.local/bin", "claude (installed under ~/.local/bin) is on the service PATH"
  end

  # launchd passes no locale; without LANG the dispatcher and its children read
  # files as US-ASCII (2026-10-15). The keys follow PATH and HOME, LANG first.
  def test_render_sets_a_utf8_locale_after_path_and_home
    env = agent.render[%r{<key>EnvironmentVariables</key>\s*<dict>(.*?)</dict>}m, 1]

    assert_equal %w[PATH HOME LANG LC_ALL], env.scan(%r{<key>([^<]+)</key>}).flatten
    assert_includes env, "<key>LANG</key>\n    <string>en_US.UTF-8</string>"
    assert_includes env, "<key>LC_ALL</key>\n    <string>en_US.UTF-8</string>"
  end

  # The Mac's installed plist was fixed by hand on 2026-10-15 with a plist editor,
  # which rewrites the file (keys sorted, tabs, the comment dropped), so no render
  # can match it byte for byte: the next ship reinstalls once, keeping that
  # plist's ruby and PATH, and every ship after it finds the plist current.
  def test_if_changed_reinstalls_a_rewritten_plist_once_keeping_its_paths_then_rests
    FileUtils.mkdir_p(File.dirname(plist))
    File.write(plist, <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0">
      <dict>
      \t<key>EnvironmentVariables</key>
      \t<dict>
      \t\t<key>HOME</key>
      \t\t<string>#{@home}</string>
      \t\t<key>LANG</key>
      \t\t<string>en_US.UTF-8</string>
      \t\t<key>LC_ALL</key>
      \t\t<string>en_US.UTF-8</string>
      \t\t<key>PATH</key>
      \t\t<string>/installed/bin:/usr/bin</string>
      \t</dict>
      \t<key>ProgramArguments</key>
      \t<array>
      \t\t<string>/installed/ruby</string>
      \t\t<string>/repo &amp; co/bin/dispatcher</string>
      \t\t<string>run</string>
      \t</array>
      </dict>
      </plist>
    XML

    shipper = agent(ruby: "/ship/ruby", path: "/ship/only/bin")
    assert_equal 0, shipper.install_if_changed
    assert_match(/template changed; reinstalling/, @out.string)
    xml = File.read(plist)
    assert_includes xml, "<string>/installed/ruby</string>", "the installed ruby is kept"
    assert_includes xml, "/installed/bin", "the installed PATH is kept"
    refute_includes xml, "/ship/only/bin", "not the ship's"
    assert_includes xml, "<key>LC_ALL</key>"

    @calls.clear
    @out.truncate(0)
    assert_equal 0, shipper.install_if_changed
    assert_match(/matches the template; nothing to refresh/, @out.string)
    assert_empty @calls, "the second ship restarts nothing"
  end

  def test_the_template_names_no_secret
    refute_match(/ANTHROPIC|TOKEN|SECRET|KEY<\/key>/, File.read(AgentMailbox::LaunchAgent::TEMPLATE))
  end

  def test_install_writes_the_plist_and_bootstraps_it_in_the_gui_domain
    assert_equal 0, agent.install

    plist = File.join(@home, "Library/LaunchAgents/studio.mcritchie.agent-dispatcher.plist")
    assert File.exist?(plist)
    assert_equal [ "bootout", "gui/501/studio.mcritchie.agent-dispatcher" ], @calls[0]
    assert_equal [ "print", "gui/501/studio.mcritchie.agent-dispatcher" ], @calls[1], "it waits for the bootout"
    assert_equal [ "bootstrap", "gui/501", plist ], @calls[2]
    assert_match(/running \(pid 4242\)/, @out.string)
  end

  def test_uninstall_unloads_and_removes
    agent.install
    assert_equal 0, agent.uninstall

    refute File.exist?(File.join(@home, "Library/LaunchAgents/studio.mcritchie.agent-dispatcher.plist"))
    assert_equal "bootout", @calls.last.first
  end

  def test_status_says_not_installed_and_installed_but_stopped
    assert_equal 3, agent.status_report
    assert_match(/not installed/, @out.string)

    agent.install
    @print = "state = not running\n\tlast exit code = 1\n"
    assert_equal 1, agent.status_report
    assert_match(/not running.*last exit 1/, @out.string)
  end

  def test_install_refuses_a_task_desk
    desk = agent(repo_root: "/Users/alex/projects/mcritchie-studio/.worktrees/some-task")

    assert_equal 2, desk.install
    assert_match(/refused: .* is a task desk under \.worktrees/, @out.string)
    assert_empty @calls, "launchctl was never called"
    refute File.exist?(File.join(@home, "Library/LaunchAgents/studio.mcritchie.agent-dispatcher.plist"))
  end

  # --- install --if-changed: the production ship's step ---------------------

  def plist = File.join(@home, "Library/LaunchAgents/studio.mcritchie.agent-dispatcher.plist")

  def test_if_changed_does_nothing_when_the_service_is_not_installed
    assert_equal 0, agent.install_if_changed

    assert_match(/not installed; nothing to refresh/, @out.string)
    assert_empty @calls, "launchctl was never called: a Mac without the service gets none"
    refute File.exist?(plist), "nothing was written"
  end

  def test_if_changed_leaves_a_current_plist_alone_even_from_another_ruby_and_path
    agent.install
    installed = File.read(plist)
    @calls.clear

    # The ship runs with its own ruby and PATH, not the installing shell's.
    shipper = agent(ruby: "/usr/local/other-ruby/bin/ruby", path: "/ship/only/bin:/usr/bin")
    refute_equal installed, shipper.render, "sanity: a plain render from the ship's environment differs"
    assert_equal 0, shipper.install_if_changed

    assert_match(/matches the template; nothing to refresh/, @out.string)
    assert_empty @calls, "a current plist is not reloaded: no bootout, no restart"
    assert_equal installed, File.read(plist)
  end

  def test_if_changed_reinstalls_when_the_template_moved_and_keeps_the_installed_paths
    agent.install
    # The installed copy predates a template change (here: an older ThrottleInterval).
    File.write(plist, File.read(plist).sub("<integer>30</integer>", "<integer>10</integer>"))
    @calls.clear

    shipper = agent(ruby: "/usr/local/other-ruby/bin/ruby", path: "/ship/only/bin")
    assert_equal 0, shipper.install_if_changed

    assert_match(/template changed; reinstalling/, @out.string)
    assert_equal [ "bootout", "gui/501/studio.mcritchie.agent-dispatcher" ], @calls[0]
    assert_equal [ "print", "gui/501/studio.mcritchie.agent-dispatcher" ], @calls[1], "it waits for the bootout"
    assert_equal [ "bootstrap", "gui/501", plist ], @calls[2]
    xml = File.read(plist)
    assert_includes xml, "<integer>30</integer>", "the new template was rendered"
    assert_includes xml, "<string>/opt/ruby/bin/ruby</string>", "the installed ruby is kept, not the ship's"
    refute_includes xml, "/ship/only/bin", "the installed PATH is kept, not the ship's"
  end

  def test_if_changed_reports_a_failed_reinstall
    agent.install
    File.write(plist, File.read(plist).sub("<true/>", "<false/>"))
    @launchctl = ->(*args) { @calls << args; [ "Bootstrap failed: 5", Status.new(args.first == "bootout") ] }

    assert_equal 1, agent.install_if_changed
    assert_match(/launchctl bootstrap failed/, @out.string)
  end

  # 2026-10-15: a bootstrap sent while the booted-out job was still exiting failed
  # with "Bootstrap failed: 5: Input/output error". Install waits for the label to
  # leave the domain first.
  def test_install_waits_for_the_old_job_to_leave_before_bootstrapping
    @loaded = true
    @linger = 4

    assert_equal 0, agent.install

    kinds = @calls.map(&:first)
    assert_equal %w[bootout print print print print print bootstrap print], kinds
    assert_equal [ AgentMailbox::LaunchAgent::BOOTOUT_POLL ] * 4, @sleeps
    assert_match(/running \(pid 4242\)/, @out.string)
  end

  def test_install_stops_waiting_at_the_bound_and_still_tries
    @loaded = true
    @linger = 10_000
    polls = (AgentMailbox::LaunchAgent::BOOTOUT_WAIT / AgentMailbox::LaunchAgent::BOOTOUT_POLL.to_f).ceil

    agent.install

    before_bootstrap = @calls.take_while { |c| c.first != "bootstrap" }
    assert_equal polls, before_bootstrap.count { |c| c.first == "print" }, "it polls up to the bound, no further"
    assert_operator @sleeps.sum, :<=, AgentMailbox::LaunchAgent::BOOTOUT_WAIT + (2 * AgentMailbox::LaunchAgent::BOOTSTRAP_BACKOFF)
    assert_match(/still loaded #{AgentMailbox::LaunchAgent::BOOTOUT_WAIT}s after bootout/, @out.string)
    assert_includes @calls.map(&:first), "bootstrap"
  end

  def test_install_retries_a_failed_bootstrap
    @bootstrap_failures = 1

    assert_equal 0, agent.install

    assert_equal 2, @calls.count { |c| c.first == "bootstrap" }
    assert_includes @sleeps, AgentMailbox::LaunchAgent::BOOTSTRAP_BACKOFF
    assert_match(/bootstrap failed \(try 1 of 3\): Bootstrap failed: 5/, @out.string)
    assert_match(/running \(pid 4242\)/, @out.string)
    refute_includes File.read(plist), AgentMailbox::LaunchAgent::FAILED_MARK
  end

  # A bootstrap that never takes leaves the job booted out (KeepAlive cannot
  # revive it). The plist stays, marked, so the next ship's --if-changed sees a
  # difference and reinstalls, instead of "matches the template" forever.
  def test_a_bootstrap_that_never_takes_leaves_the_next_ship_able_to_retry
    agent.install
    File.write(plist, File.read(plist).sub("<integer>30</integer>", "<integer>10</integer>")) # an older template
    @bootstrap_failures = 3
    @calls.clear

    assert_equal 1, agent.install_if_changed
    assert_equal 3, @calls.count { |c| c.first == "bootstrap" }
    assert_match(/The service is NOT loaded/, @out.string)
    xml = File.read(plist)
    assert_includes xml, AgentMailbox::LaunchAgent::FAILED_MARK
    assert_match(%r{</plist>\n<!-- bootstrap failed [^\n]*Input/output error[^\n]*-->\n\z}, xml)
    mark = xml[/<!-- bootstrap failed(.*)-->\n\z/, 1]
    refute_includes mark, "--", "the mark is a well-formed XML comment"

    @out.truncate(0)
    @calls.clear
    assert_equal 0, agent.install_if_changed, "the next ship retries, and this time it takes"
    assert_match(/template changed; reinstalling/, @out.string)
    refute_includes File.read(plist), AgentMailbox::LaunchAgent::FAILED_MARK
    assert_equal agent.render, File.read(plist)
  end

  def test_if_changed_falls_back_to_this_process_paths_for_a_hand_edited_plist
    FileUtils.mkdir_p(File.dirname(plist))
    File.write(plist, "<plist>hand edited</plist>")

    assert_equal 0, agent.install_if_changed
    assert_match(/template changed; reinstalling/, @out.string)
    assert_equal agent.render, File.read(plist)
  end

  # A code restart is `exit 0`. launchd restarts that only under plain
  # KeepAlive true; KeepAlive {SuccessfulExit: false} would leave it stopped.
  def test_keep_alive_restarts_on_a_clean_exit
    xml = File.read(AgentMailbox::LaunchAgent::TEMPLATE)

    assert_match(%r{<key>KeepAlive</key>\s*<true/>}, xml)
    refute_match(/SuccessfulExit/, xml)
  end
end
