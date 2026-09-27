require "test_helper"

# [unit] READING A PHOTOGRAPH'S TITLE FOR WHOSE FACE IS IN IT.
#
# THE MEASURED CASE THIS OBJECT EXISTS FOR, first and last in this file: a search for
# "Drew Lock" returned `Drew Hutton.jpg`, whose face scored 90 and ranked SECOND in the
# identity (measured 2026-09-25 on look `1943e690035b`). A clear photograph of a
# stranger beats a helmeted photograph of the right man on every visibility score there
# is, and the title was printed on the tile the whole time.
#
# HALF THESE CASES ARE THE FALSE POSITIVES, deliberately. The cost of refusing a
# photograph that IS our person is a reference thrown away, and titles are name-shaped
# prose full of teams, months and places — so each of those shapes gets a case that
# asserts it is NOT read as a second person.
#
# NO NETWORK, NO DATABASE, NO SPEND: this is string reading.
class Appearances::PersonNamingTest < ActiveSupport::TestCase
  PN = Appearances::PersonNaming

  def kind(title, person = "Drew Lock") = PN.judge(title, person).kind

  # ---- the person is named ------------------------------------------------------

  test "every word of the name present is the person, in either order" do
    assert_equal PN::NAMES_PERSON, kind("Drew Lock, 22 October 2023")
    assert_equal PN::NAMES_PERSON, kind("Lock, Drew - Seahawks camp")
    assert_equal PN::NAMES_PERSON, kind("Drew_Lock_10_22_2023.jpg")
  end

  # THE TITLE NAMES A STRANGER **AND** OUR MAN. The photograph is of our man too, so the
  # naming check must not throw it away — whether it holds two FACES is a different
  # question and Appearances::FaceVisibility answers that one.
  test "our person's whole name wins over a stranger standing beside him" do
    assert_equal PN::NAMES_PERSON, kind("Drew Lock and Drew Hutton at practice")
  end

  # ---- somebody else is named ---------------------------------------------------

  # THE DEFECT. Shares the given name, differs on the surname.
  test "a shared given name with a different surname is somebody else" do
    verdict = PN.judge("Drew Hutton.jpg", "Drew Lock")

    assert verdict.names_other?
    assert_equal "Hutton", verdict.other_name,
                 "the page has to be able to SAY which name it read, not just refuse"
  end

  test "a shared surname with a different given name is somebody else" do
    assert_equal PN::NAMES_OTHER, kind("Keenan Allen.jpg", "Josh Allen")
    assert_equal PN::NAMES_OTHER, kind("Bo Nix throws to Marvin Mims", "Bo Jackson")
  end

  # SURNAME-FIRST CAPTIONS ARE COMMON IN ARCHIVES, and the stranger's name can sit on
  # either side of the word we matched.
  test "a stranger's name is read from the left as well as the right" do
    assert_equal PN::NAMES_OTHER, kind("Hutton, Drew", "Drew Lock")
  end

  # ---- the false positives this must NOT produce --------------------------------

  # THE CAPITAL IS THE DISCRIMINATOR, which is why this is not a stop-word list. A
  # lowercase neighbour is prose, not a person.
  test "an ordinary word beside the name is not a second person" do
    assert_equal PN::UNKNOWN, kind("Drew at Broncos practice")
    assert_equal PN::UNKNOWN, kind("the lock on the gate")
  end

  # COMMONS TITLES ARE DATE-HEAVY. A capitalised month is not a surname.
  test "a month beside the name is not a second person" do
    assert_equal PN::UNKNOWN, kind("Drew in October 2023")
    assert_equal PN::UNKNOWN, kind("Lock, October.jpg")
  end

  test "a file extension beside the name is not a second person" do
    assert_equal PN::UNKNOWN, kind("Drew.JPG")
  end

  # AN INITIAL IS NOT A SURNAME. Refusing on one would throw away the right man's own
  # photograph on the strength of his middle initial.
  test "an initial beside the name is not a second person" do
    assert_equal PN::UNKNOWN, kind("Drew H. at camp", "Drew Lock")
  end

  # ---- no opinion available -----------------------------------------------------

  # THE HONEST LIMIT, stated as a test so nobody reads this object as a complete
  # answer: a stranger who shares NO word with our person's name is invisible to it.
  # Catching that needs a look at the FACE, which costs money and lives elsewhere.
  test "a stranger sharing no name word with ours is unknown, not refused" do
    assert_equal PN::UNKNOWN, kind("Russell Wilson.jpg", "Drew Lock")
  end

  test "an absent title or an absent person name is never an accusation" do
    assert_equal PN::UNKNOWN, kind(nil)
    assert_equal PN::UNKNOWN, kind("")
    assert_equal PN::UNKNOWN, kind("Drew Hutton.jpg", nil)
    assert_equal PN::UNKNOWN, kind("Drew Hutton.jpg", "")
  end

  test "a lowercase title carries no capital to read, so it accuses nobody" do
    assert_equal PN::UNKNOWN, kind("drew hutton.jpg", "Drew Lock")
  end

  # ---- the predicate PhotoMerit now delegates to --------------------------------

  # THE READING TIGHTENED WHEN IT MOVED HERE. PhotoMerit used to ask
  # `title.include?("lock")`, a SUBSTRING test that awarded Drew Lock's name bonus to a
  # photograph of a locksmith.
  test "a name word inside a longer word is not the name" do
    refute PN.names_person?("Locksmith Drew's van", "Drew Lock")
    refute Appearances::PhotoMerit.names_person?(
      Appearances::ImageSearch::Result.new(image_url: "https://x.test/a.jpg",
                                           title: "Locksmith Drew's van"),
      "Drew Lock"
    )
  end
end
