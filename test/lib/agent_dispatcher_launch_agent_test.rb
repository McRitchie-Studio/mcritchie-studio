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
    @launchctl = lambda do |*args|
      @calls << args
      args.first == "print" ? [ @print, Status.new(true) ] : [ "", Status.new(true) ]
    end
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(@home)

  def agent(**opts)
    AgentMailbox::LaunchAgent.new(**{ home: @home, repo_root: "/repo & co", ruby: "/opt/ruby/bin/ruby", path: "/usr/bin",
                                      uid: 501, launchctl: @launchctl, out: @out }.merge(opts))
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

  def test_the_template_names_no_secret
    refute_match(/ANTHROPIC|TOKEN|SECRET|KEY<\/key>/, File.read(AgentMailbox::LaunchAgent::TEMPLATE))
  end

  def test_install_writes_the_plist_and_bootstraps_it_in_the_gui_domain
    assert_equal 0, agent.install

    plist = File.join(@home, "Library/LaunchAgents/studio.mcritchie.agent-dispatcher.plist")
    assert File.exist?(plist)
    assert_equal [ "bootout", "gui/501/studio.mcritchie.agent-dispatcher" ], @calls[0]
    assert_equal [ "bootstrap", "gui/501", plist ], @calls[1]
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
    assert_equal [ "bootstrap", "gui/501", plist ], @calls[1]
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
