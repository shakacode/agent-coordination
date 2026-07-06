# frozen_string_literal: true

module TaskOne
  # BUG (sim issue 1): returns the sum including negatives; spec says
  # negatives are excluded from the total.
  def self.positive_sum(numbers)
    numbers.sum
  end
end
