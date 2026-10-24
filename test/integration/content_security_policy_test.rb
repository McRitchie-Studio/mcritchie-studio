require "test_helper"

# [unit] hub-report-only-csp: the hub sends its Content-Security-Policy as
# Content-Security-Policy-Report-Only on every HTML page, with a fresh nonce per
# request, and every inline <script> the hub's layout, its views and the engine's
# head render carries that nonce (config/initializers/content_security_policy.rb).
class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  REPORT_ONLY = "Content-Security-Policy-Report-Only".freeze
  # Script types a browser executes, so CSP governs them. Data blocks
  # (application/json, application/ld+json, text/template) are not scripts.
  EXECUTABLE_TYPES = [ nil, "", "text/javascript", "application/javascript", "module", "importmap" ].freeze

  # Inline scripts the ENGINE renders with no nonce, each allowed by its pinned hash
  # until the engine nonces it. Lapses on its own: once the locked engine's file
  # renders a nonce, the lapse test below fails and asks for the entry's removal.
  ENGINE_PENDING_NONCE = {
    "studio/_at_time_script" => "app/views/studio/_at_time_script.html.erb"
  }.freeze

  def expected_policy(nonce)
    hashes = HubCsp::PINNED_SCRIPT_HASHES.values.map { |hash| "'#{hash}'" }.join(" ")
    [
      "default-src 'self'",
      "script-src 'self' 'unsafe-eval' 'report-sample' https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.js #{hashes} 'nonce-#{nonce}'",
      "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.css",
      "img-src 'self' data: blob: https:",
      "media-src 'self' blob: https://assets.mcritchie.studio https://*.r2.cloudflarestorage.com",
      "font-src 'self' data:",
      "connect-src 'self' ws://www.example.com",
      "frame-src 'self' https://calendar.google.com",
      "worker-src 'self' blob:",
      "object-src 'none'",
      "frame-ancestors 'self'",
      "base-uri 'self'",
      "form-action 'self' https://accounts.google.com",
      "report-uri /csp_reports",
      "report-to csp-endpoint"
    ].join("; ")
  end

  def header_nonce
    response.headers[REPORT_ONLY].to_s[/'nonce-([^']+)'/, 1]
  end

  def inline_scripts
    Nokogiri::HTML5(response.body).css("script").reject { |s| s["src"] }.select { |s| EXECUTABLE_TYPES.include?(s["type"]) }
  end

  def script_hash(script)
    "sha256-#{Base64.strict_encode64(Digest::SHA256.digest(script.text))}"
  end

  # Every inline script on the page either carries the header's nonce or is an
  # engine script still pending its nonce (allowed by hash).
  def assert_every_inline_script_nonced(page)
    nonce = header_nonce
    assert nonce.present?, "#{page}: no nonce in the header"
    pending_hashes = ENGINE_PENDING_NONCE.keys.map { |key| HubCsp::PINNED_SCRIPT_HASHES.fetch(key) }
    scripts = inline_scripts
    assert_operator scripts.size, :>=, 3, "#{page}: the scan found almost no inline scripts; is it reading the page?"
    unnonced = scripts.reject { |s| s["nonce"] == nonce || pending_hashes.include?(script_hash(s)) }
    assert_empty unnonced.map { |s| s.text.strip[0, 80] }, "#{page}: inline scripts without the request's nonce"
  end

  test "the landing page sends the exact report-only policy and no enforced one" do
    get root_path
    assert_response :success
    assert_nil response.headers["Content-Security-Policy"], "report-only phase: nothing may be enforced yet"
    assert_equal expected_policy(header_nonce), response.headers[REPORT_ONLY]
    assert_equal 'csp-endpoint="/csp_reports"', response.headers["Reporting-Endpoints"]
  end

  test "/build sends the exact policy and every inline script carries its nonce" do
    get build_path
    assert_response :success
    assert_equal expected_policy(header_nonce), response.headers[REPORT_ONLY]
    assert_every_inline_script_nonced("/build")
  end

  test "/tasks, signed in, sends the exact policy and every inline script carries its nonce" do
    log_in_as(users(:alex))
    get tasks_path
    assert_response :success
    assert_equal expected_policy(header_nonce), response.headers[REPORT_ONLY]
    assert_every_inline_script_nonced("/tasks")
  end

  test "every inline script on the landing page carries the nonce, the meta tag included" do
    get root_path
    assert_every_inline_script_nonced("/")
    meta = Nokogiri::HTML5(response.body).at_css('meta[name="csp-nonce"]')
    assert_equal header_nonce, meta&.[]("content"), "csp_meta_tag must publish the same nonce"
  end

  # A Turbo visit keeps the document, and with it the policy and nonce of its full
  # load. A nonce reused across requests would let a script a later page brings in
  # run under the first page's policy (memory: turbo-nonce-carry-defeats-strict-csp).
  test "a Turbo visit gets a fresh nonce, never the previous page's" do
    log_in_as(users(:alex))
    get root_path
    first = header_nonce
    first_scripts = inline_scripts.filter_map { |s| s["nonce"] }

    get tasks_path, headers: { "Turbo-Visit" => "true", "Accept" => "text/html, application/xhtml+xml" }
    second = header_nonce
    assert first.present? && second.present?
    refute_equal first, second, "the nonce must be minted per request"
    refute_includes response.body, first, "the Turbo-visited page must not carry the previous page's nonce"
    assert_includes first_scripts, first
    assert inline_scripts.any? { |s| s["nonce"] == second }
  end

  test "every pinned hash is the hash of a script the layout renders" do
    get root_path
    rendered = inline_scripts.map { |s| script_hash(s) }
    stale = HubCsp::PINNED_SCRIPT_HASHES.reject { |_name, hash| rendered.include?(hash) }
    current = inline_scripts.reject { |s| s["src"] }.map { |s| "#{script_hash(s)}  #{s.text.strip[0, 60]}" }
    assert_empty stale, "Pinned script hashes match no rendered script; a layout script changed. " \
                        "Rendered hashes:\n#{current.join("\n")}"
  end

  test "an engine script pending its nonce lapses once the locked engine nonces it" do
    engine = Gem.loaded_specs.fetch("studio-engine").full_gem_path
    ENGINE_PENDING_NONCE.each do |name, file|
      source = File.read(File.join(engine, file))
      refute_match(/nonce/, source.lines.grep(/<script|tag\.script|javascript_tag/).join,
                   "#{file} now renders a nonce: drop #{name} from ENGINE_PENDING_NONCE (keep its hash for Turbo visits)")
    end
  end

  test "the policy is report-only with a per-request nonce on script-src only" do
    config = Rails.application.config
    assert config.content_security_policy_report_only
    assert_equal %w[script-src], config.content_security_policy_nonce_directives
    request = ActionDispatch::TestRequest.create
    nonces = Array.new(3) { config.content_security_policy_nonce_generator.call(request) }
    assert_equal 3, nonces.uniq.size
    # Read through the directives hash, never by calling the directive method (a setter).
    refute_includes config.content_security_policy.directives["script-src"], "'unsafe-inline'"
  end
end
