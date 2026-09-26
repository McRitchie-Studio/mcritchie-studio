require "test_helper"

# [unit] THE FREE SCORE — what it can decide, and the case it provably cannot.
#
# Its only job is choosing who is worth PAYING Appearances::FaceVisibility to look
# at. The last test in this file is the important one: it pins the LIMIT of this
# object, so nobody later reads a high merit score as "this shows a face" and
# deletes the classifier that actually answers that.
class Appearances::PhotoMeritTest < ActiveSupport::TestCase
  def hit(url, **rest) = Appearances::ImageSearch::Result.new(image_url: url, **rest)

  def score(result, person_name: "Josh Allen")
    Appearances::PhotoMerit.score(result, person_name: person_name)
  end

  # THE CLASS IT EXISTS TO CATCH. Measured on a real Wikimedia Commons answer for
  # "Drew Lock" (2026-09-26): 15 of 20 results were scanned books and PDFs. Every
  # one it recognises here is an image we do not pay a vision model to look at.
  test "a scanned document scores zero however good its other metadata looks" do
    scan = hit("https://upload.example.com/page1-500px-media_guide.pdf.jpg",
               title: "Josh Allen media guide", width: 800, height: 1172, position: 1)

    assert_equal 0.0, score(scan),
                 "a name match, a portrait ratio and hit 1 must not rescue a book page"
  end

  test "documents are recognised from the url when there is no title at all" do
    %w[
      https://x.test/a.pdf
      https://x.test/b.djvu
      https://x.test/page1-500px-c.pdf.jpg
      https://x.test/d.svg
    ].each do |url|
      assert Appearances::PhotoMerit.document?(hit(url)), "#{url} should read as a document"
    end
  end

  test "an ordinary photograph is not mistaken for a document" do
    refute Appearances::PhotoMerit.document?(hit("https://x.test/player-portrait.jpg"))
  end

  # NAMING THE PERSON IS THE STRONGEST FREE SIGNAL we have, and it has to be an
  # ALL-WORDS match: "Drew Hutton" was a real neighbour in a real answer for
  # "Drew Lock", and a first-name match would have promoted a photograph of a
  # different man.
  test "a title naming the person scores above one that does not" do
    named = hit("https://x.test/a.jpg", title: "Josh Allen warms up", width: 600, height: 800)
    other = hit("https://x.test/b.jpg", title: "Josh Hutton warms up", width: 600, height: 800)

    assert_operator score(named), :>, score(other)
  end

  test "a partial name match earns nothing" do
    partial = hit("https://x.test/a.jpg", title: "Josh Hutton", width: 600, height: 800)
    none = hit("https://x.test/b.jpg", title: "A quarterback", width: 600, height: 800)

    assert_equal score(partial), score(none)
  end

  test "a missing person name never raises and never awards the bonus" do
    result = hit("https://x.test/a.jpg", title: "Somebody", width: 600, height: 800)

    assert_equal score(result, person_name: nil), score(result, person_name: "")
  end

  # A DISTANT CROWD SHOT. The one shape signal that carries real information —
  # measured on the operator's example, where the 3207x2135 hit was a sideline
  # photograph with the subject small in frame.
  test "a wide landscape scores below a portrait of the same subject" do
    portrait = hit("https://x.test/a.jpg", title: "Josh Allen", width: 686, height: 930)
    wide = hit("https://x.test/b.jpg", title: "Josh Allen", width: 3207, height: 2135)

    assert_operator score(portrait), :>, score(wide)
  end

  test "an image too small to carry a face is penalised" do
    tiny = hit("https://x.test/a.jpg", title: "Josh Allen", width: 80, height: 100)
    full = hit("https://x.test/b.jpg", title: "Josh Allen", width: 600, height: 800)

    assert_operator score(full), :>, score(tiny)
  end

  # NO DIMENSIONS IS NOT A PENALTY. The Serper response shape is unverified, so a
  # provider that omits width and height must not have every result buried.
  test "a result with no dimensions at all is still scored sanely" do
    bare = hit("https://x.test/a.jpg", title: "Josh Allen", position: 1)

    assert_operator score(bare), :>, 0.0
    assert_operator score(bare), :<=, 1.0
  end

  test "the provider's own rank breaks ties and decays" do
    first = hit("https://x.test/a.jpg", position: 1)
    tenth = hit("https://x.test/b.jpg", position: 10)

    assert_operator score(first), :>, score(tenth)
  end

  test "every score stays inside the unit range" do
    [
      hit("https://x.test/a.jpg"),
      hit("https://x.test/b.jpg", title: "Josh Allen", width: 600, height: 800, position: 1),
      hit("https://x.test/c.pdf", title: "Josh Allen", width: 10, height: 9999, position: 99)
    ].each do |result|
      assert_includes 0.0..1.0, score(result)
    end
  end

  # ⚠ THE LIMIT, PINNED AS A TEST so a later reader cannot mistake merit for an
  # answer to the operator's question.
  #
  # This is the operator's own labelled pair, with the shapes and titles measured
  # off the real files: a bare-faced photograph and a helmeted one, from the same
  # source, of the same person, days apart. Merit scores them IDENTICALLY, which is
  # correct — no metadata distinguishes them — and is exactly why
  # Appearances::FaceVisibility exists and why deleting it to save money would
  # silently undo this whole feature.
  test "merit provably cannot separate a helmet from a bare face" do
    bare = hit("https://upload.example.com/Drew_Lock_10_22_2023.jpg",
               title: "Drew Lock, 22 October 2023", width: 556, height: 780, position: 1)
    helmet = hit("https://upload.example.com/Drew_Lock_12_18_2023.jpg",
                 title: "Drew Lock, 18 December 2023", width: 686, height: 930, position: 1)

    assert_equal score(bare, person_name: "Drew Lock"), score(helmet, person_name: "Drew Lock"),
                 "if these ever differ, the difference is an accident of shape, not a judgement " \
                 "about faces - do not build a ranking on it"
  end
end
