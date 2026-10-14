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
    AgentMailbox::LaunchAgent.new(home: @home, repo_root: "/repo & co", ruby: "/opt/ruby/bin/ruby", path: "/usr/bin",
                                  uid: 501, launchctl: @launchctl, out: @out, **opts)
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
end
