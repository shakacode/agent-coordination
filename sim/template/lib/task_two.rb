# frozen_string_literal: true

module TaskTwo
  # BUG (sim issue 2): downcases the whole string; spec says title-case
  # each word (first letter upper, rest lower).
  def self.title_case(text)
    text.downcase
  end
end
