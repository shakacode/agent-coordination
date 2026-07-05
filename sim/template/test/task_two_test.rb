# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/task_two"

class TaskTwoTest < Minitest::Test
  def test_title_cases_words
    assert_equal "Hello Wide World", TaskTwo.title_case("hello WIDE world")
  end
end
