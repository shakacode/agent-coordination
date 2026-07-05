# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/task_three"

class TaskThreeTest < Minitest::Test
  def test_counts_inclusively
    assert_equal 5, TaskThree.inclusive_count(3, 7)
  end
end
