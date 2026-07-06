# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/task_one"

class TaskOneTest < Minitest::Test
  def test_negatives_are_excluded
    assert_equal 6, TaskOne.positive_sum([1, 2, 3, -5])
  end

  def test_all_negative_is_zero
    assert_equal 0, TaskOne.positive_sum([-1, -2])
  end
end
