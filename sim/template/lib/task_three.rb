# frozen_string_literal: true

module TaskThree
  # BUG (sim issue 3): off-by-one; spec says inclusive range count.
  def self.inclusive_count(first, last)
    last - first
  end
end
