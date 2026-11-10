# frozen_string_literal: true

require "test_helper"

# [unit] MarketingKit::Office.python builds the shared venv once, under a lock,
# and trusts it only after pip has finished (its .ready marker). CI's parallel
# workers once ran a half-built venv and failed on `import openpyxl`.
class MarketingKitOfficePythonTest < ActiveSupport::TestCase
  Office = MarketingKit::Office

  setup { Office.instance_variable_set(:@python, nil) }
  teardown { Office.instance_variable_set(:@python, nil) }

  def with_cache
    Dir.mktmpdir do |root|
      calls = []
      Office.stub(:cache_root, root) do
        # The real `python3 -m venv DIR` creates DIR; the stand-in does the same.
        run = lambda do |*cmd|
          FileUtils.mkdir_p(cmd[3]) if cmd[2] == "venv"
          calls << cmd.first(3)
          ""
        end
        Office.stub(:run!, run) { yield root, calls }
      end
    end
  end

  test "a missing venv is built, then marked ready after pip" do
    with_cache do |root, calls|
      bin = Office.python
      assert_equal 2, calls.size, "venv, then pip"
      assert_equal %w[python3 -m venv], calls.first
      assert_equal ["-m", "pip"], calls.last[1, 2]
      assert File.exist?(File.join(File.dirname(File.dirname(bin)), ".ready"))
      assert_equal root, File.dirname(File.dirname(File.dirname(bin)))
    end
  end

  test "a venv whose bin/python exists but has no ready marker is finished, not trusted" do
    with_cache do |_root, calls|
      dir = File.dirname(File.dirname(Office.python))
      Office.instance_variable_set(:@python, nil)
      File.delete(File.join(dir, ".ready"))
      calls.clear
      Office.python
      assert_equal 2, calls.size, "pip runs again until the marker exists"
    end
  end

  test "a ready venv is used as it is" do
    with_cache do |_root, calls|
      Office.python
      Office.instance_variable_set(:@python, nil)
      calls.clear
      Office.python
      assert_empty calls
    end
  end
end
