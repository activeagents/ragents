# frozen_string_literal: true

require "test_helper"

class RagentsTest < Minitest::Test
  def test_version_exists
    refute_nil Ragents::VERSION
  end

  def test_configuration
    Ragents.configure do |config|
      config.max_iterations = 5
      config.timeout = 60
    end

    assert_equal 5, Ragents.configuration.max_iterations
    assert_equal 60, Ragents.configuration.timeout
  end
end
