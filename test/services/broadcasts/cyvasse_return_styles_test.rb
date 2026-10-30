require "test_helper"

# [unit] Broadcasts::CyvasseReturn picks each return style's subject from the
# reader's merge fields (task cyvasse-three-return-emails).
class Broadcasts::CyvasseReturnStylesTest < ActiveSupport::TestCase
  R = Broadcasts::CyvasseReturn

  test "the three styles map to registered templates and resolvers" do
    assert_equal %w[cyvasse_record cyvasse_challenge cyvasse_founder_note], R::STYLES.values
    R::STYLES.each_value do |key|
      assert Broadcast::TEMPLATES.key?(key), key
      assert Broadcast::SUBJECT_RESOLVERS.key?(key), key
      assert_not Broadcast::TEMPLATE_MERGE_FIELDS.key?(key), "#{key} must stage every reader"
    end
  end

  test "record: history line at 5+ games, account line below, plain line with no username" do
    assert_equal R::Record::HISTORY_SUBJECT, R::Record.subject_template({ "username" => "vey", "games" => 5 })
    assert_equal R::Record::ACCOUNT_SUBJECT, R::Record.subject_template({ "username" => "vey", "games" => 4 })
    assert_equal R::Record::ACCOUNT_SUBJECT, R::Record.subject_template({ "username" => "vey" })
    assert_equal R::Record::PLAIN_SUBJECT, R::Record.subject_template({ "games" => 50 })
    assert_equal R::Record::PLAIN_SUBJECT, R::Record.subject_template(nil)
  end

  test "challenge and founder: personal line with a username, plain without" do
    [ R::Challenge, R::FounderNote ].each do |style|
      assert_equal style::PERSONAL_SUBJECT, style.subject_template({ "username" => "vey" })
      assert_equal style::PLAIN_SUBJECT, style.subject_template({ "username" => "" })
      assert_equal style::PLAIN_SUBJECT, style.subject_template(nil)
    end
  end

  test "Broadcast#subject_for fills the fields through each resolver" do
    record = Broadcast.new(template_key: "cyvasse_record", subject: "ignored")
    assert_equal "vey, your 57 games of Cyvasse are still here", record.subject_for({ "username" => "vey", "games" => 57 })
    assert_equal "Your Cyvasse account is still here", record.subject_for({})
    assert_equal "vey, your move on Cyvasse",
                 Broadcast.new(template_key: "cyvasse_challenge", subject: "x").subject_for({ "username" => "vey" })
    assert_equal "I rebuilt Cyvasse", Broadcast.new(template_key: "cyvasse_founder_note", subject: "x").subject_for({})
  end
end
