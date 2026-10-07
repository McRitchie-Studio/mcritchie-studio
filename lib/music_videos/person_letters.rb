# frozen_string_literal: true

module MusicVideos
  # The letter a person on screen goes by in clip prompts and on lettered
  # reference frames (recast pipeline, piece 16). Fixed per SOURCE video:
  # Person N is the Nth letter (Person 1 = A, Person 2 = B, ... Person 27 = AA),
  # so a letter means the same person in every clip, every alt video and every
  # prompt. A letter is never a name: only the operator maps people to real people.
  module PersonLetters
    module_function

    def for(ordinal)
      n = Integer(ordinal)
      raise ArgumentError, "a person ordinal starts at 1, got #{ordinal.inspect}" unless n.positive?

      letters = +""
      while n.positive?
        n, rem = (n - 1).divmod(26)
        letters.prepend((65 + rem).chr)
      end
      letters
    end

    # The ordinal a letter stands for, or nil when it is not a letter.
    def ordinal(letter)
      text = letter.to_s
      return nil unless text.match?(/\A[A-Z]{1,2}\z/)

      text.each_char.reduce(0) { |n, c| (n * 26) + (c.ord - 64) }
    end
  end
end
