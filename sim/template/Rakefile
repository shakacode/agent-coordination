# frozen_string_literal: true

require "minitest/test_task"

Minitest::TestTask.create(:test) { |t| t.test_globs = ["test/**/*_test.rb"] }
task default: :test
