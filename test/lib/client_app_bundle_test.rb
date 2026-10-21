require "test_helper"
require "tmpdir"

# [unit] ClientAppBundle: the rules a client app's static bundle is held to before
# it is published (docs/agents/system/client-app-host.md). The CLI and the hub
# run the same class.
class ClientAppBundleTest < ActiveSupport::TestCase
  PAGE = "<!doctype html><title>x</title><main data-studio-content><h1>x</h1></main>"

  def bundle(files) = ClientAppBundle.new({ "index.html" => PAGE }.merge(files))

  def assert_refused(files, pattern)
    errors = bundle(files).errors
    assert errors.any? { |e| e.match?(pattern) }, "expected #{pattern.inspect} in #{errors.inspect}"
  end

  test "[unit] a plain static bundle is valid and its manifest types every file" do
    b = bundle("app.js" => "x", "assets/site.css" => "y", "img/logo.svg" => "<svg/>", "fonts/a.woff2" => "f",
               "data.json" => "{}", "favicon.ico" => "i", "robots.txt" => "t", "a.png" => "p", "b.jpg" => "j",
               "c.webp" => "w", "d.JPEG" => "j")

    assert_empty b.errors
    assert_equal "text/javascript; charset=utf-8", b.manifest["app.js"]["content_type"]
    assert_equal "text/css; charset=utf-8", b.manifest["assets/site.css"]["content_type"]
    assert_equal "image/svg+xml", b.manifest["img/logo.svg"]["content_type"]
    assert_equal "font/woff2", b.manifest["fonts/a.woff2"]["content_type"]
    assert_equal "image/jpeg", b.manifest["d.JPEG"]["content_type"]
    assert_equal Digest::SHA256.hexdigest("x"), b.manifest["app.js"]["sha256"]
    assert_equal 1, b.manifest["app.js"]["size"]
  end

  test "[unit] index.html is required at the root" do
    errors = ClientAppBundle.new({ "app/index.html" => "x" }).errors
    assert(errors.any? { |e| e.include?("index.html is required") })
    assert_includes ClientAppBundle.new({}).errors, "the bundle is empty"
  end

  test "[unit] server code and unknown file types are refused" do
    %w[server.rb index.php page.html.erb run.sh app.py Gemfile .htaccess main.wasm x.mjs].each do |name|
      assert_refused({ name => "code" }, /not a static file type|dot-file/)
    end
  end

  test "[unit] traversal, absolute, dot-file and odd paths are refused" do
    assert_refused({ "../escape.html" => "x" }, /dot-file or an empty, '\.' or '\.\.' segment/)
    assert_refused({ "a/../../b.html" => "x" }, /'\.\.' segment/)
    assert_refused({ "/etc/passwd.txt" => "x" }, /not a relative path/)
    assert_refused({ "a\\b.html" => "x" }, /not a relative path/)
    assert_refused({ "a//b.html" => "x" }, /empty/)
    assert_refused({ ".env.txt" => "x" }, /dot-file/)
    assert_refused({ "assets/.hidden.js" => "x" }, /dot-file/)
    assert_refused({ "my page.html" => "x" }, /character outside/)
    assert_refused({ "nul\0.html" => "x" }, /not a relative path/)
    assert_refused({ "#{(%w[a] * 7).join('/')}.js" => "x" }, /nested more than/)
    assert_refused({ "#{'a' * 210}.js" => "x" }, /too long/)
  end

  test "[unit] size and count caps" do
    big = "x" * (ClientAppBundle::MAX_FILE_BYTES + 1)
    assert_refused({ "big.js" => big }, /over #{ClientAppBundle::MAX_FILE_BYTES} for one file/)

    halves = (1..3).to_h { |i| [ "part#{i}.js", "x" * (2 * 1024 * 1024) ] }
    assert_refused(halves, /over #{ClientAppBundle::MAX_BYTES}\z/)

    many = (1..ClientAppBundle::MAX_FILES).to_h { |i| [ "f#{i}.js", "x" ] }
    assert_refused(many, /files, over #{ClientAppBundle::MAX_FILES}/)
  end

  test "[unit] validate! raises Invalid carrying every error" do
    error = assert_raises(ClientAppBundle::Invalid) { ClientAppBundle.new({ "x.php" => "<?php" }).validate! }
    assert_equal 2, error.errors.size
  end

  test "[unit] from_directory reads regular files and refuses symlinks" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "assets"))
      File.write(File.join(dir, "index.html"), PAGE)
      File.write(File.join(dir, "assets/app.js"), "1")
      b = ClientAppBundle.from_directory(dir)
      assert_equal %w[assets/app.js index.html], b.files.keys.sort
      assert_empty b.errors

      File.symlink("/etc/hosts", File.join(dir, "hosts.txt"))
      File.symlink("/tmp", File.join(dir, "linked"))
      error = assert_raises(ClientAppBundle::Invalid) { ClientAppBundle.from_directory(dir) }
      assert_includes error.errors, "hosts.txt is a symlink"
      assert_includes error.errors, "linked is a symlink"
    end
  end

  test "[unit] from_directory stops reading once the bundle is too big" do
    Dir.mktmpdir do |dir|
      3.times { |i| File.write(File.join(dir, "part#{i}.js"), "x" * (2 * 1024 * 1024)) }
      error = assert_raises(ClientAppBundle::Invalid) { ClientAppBundle.from_directory(dir) }
      assert(error.errors.any? { |e| e.include?("passes") })
    end
  end

  test "[unit] the demo bundle fixture is valid" do
    assert_empty ClientAppBundle.from_directory(Rails.root.join("test/fixtures/files/client_bundles/demo")).errors
  end
end
