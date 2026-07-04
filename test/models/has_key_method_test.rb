require "test_helper"

# [unit] HasKeyMethod — the shared key_method (+ lang badge) normalization behind
# AtomicEvent and AtomicAction. infer_lang and normalize_pair are PURE module
# functions; the ladder's terminal default is bash (the trail is mostly shell).
class HasKeyMethodTest < ActiveSupport::TestCase
  test "[unit] infer_lang recognizes ruby, sql, and js, and defaults to bash" do
    assert_equal "ruby", HasKeyMethod.infer_lang("User.find_by(email: 'a@b.c')")
    assert_equal "ruby", HasKeyMethod.infer_lang("Studio::Link.consume!(token)")
    assert_equal "sql",  HasKeyMethod.infer_lang("SELECT * FROM tasks WHERE stage = 'submitted'")
    assert_equal "js",   HasKeyMethod.infer_lang("const rows = await page.locator('#col-insights')")
    assert_equal "bash", HasKeyMethod.infer_lang("bin/task list --stage submitted")
    assert_equal "bash", HasKeyMethod.infer_lang("git log --oneline -5")
  end

  test "[unit] infer_lang is nil for blank code" do
    assert_nil HasKeyMethod.infer_lang(nil)
    assert_nil HasKeyMethod.infer_lang("   ")
  end

  test "[unit] normalize_pair trims to caps, infers a missing lang, and keeps an explicit one" do
    pair = HasKeyMethod.normalize_pair("User.find_by(email: ...)", nil)
    assert_equal "User.find_by(email: ...)", pair[:key_method]
    assert_equal "ruby", pair[:key_method_lang]

    explicit = HasKeyMethod.normalize_pair("bin/rails runner 'User.find_by(id: 1)'", "BASH")
    assert_equal "bash", explicit[:key_method_lang], "explicit lang wins (downcased) over inference"

    long = HasKeyMethod.normalize_pair("x" * 900, nil)
    assert_equal HasKeyMethod::MAX_KEY_METHOD_LENGTH, long[:key_method].length
  end

  test "[unit] normalize_pair clears BOTH sides for blank code — the pair travels together" do
    pair = HasKeyMethod.normalize_pair("  ", "ruby")
    assert_nil pair[:key_method]
    assert_nil pair[:key_method_lang]
  end

  test "[unit] the before_validation applies the pair on both models" do
    event = AtomicEvent.create!(session_id: "s-km", category: "Explore", reason_slug: "orient",
                                opened_at: Time.current, key_method: "  bin/task list  ")
    assert_equal "bin/task list", event.key_method
    assert_equal "bash", event.key_method_lang

    action = AtomicAction.create!(session_id: "s-km", kind: "bash", outcome: "ok", actor: "agent",
                                  occurred_at: Time.current, key_method: "Task.find_by(slug: 'x')")
    assert_equal "ruby", action.key_method_lang
  end
end
