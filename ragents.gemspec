require_relative "lib/ragents/version"

Gem::Specification.new do |spec|
  spec.name        = "ragents"
  spec.version     = Ragents::VERSION
  spec.authors     = ["Justin Bowen"]
  spec.email       = ["JusBowen@gmail.com"]

  spec.summary     = "A Ractor-based concurrency library for AI agent interactions."
  spec.description = <<~DESC
    Ragents is a pure Ruby, Ractor-based AI agent framework designed for concurrent,
    isolated agent execution. It provides message-passing architecture, tool-based
    actions, and provider-agnostic LLM integration without Rails dependencies.
  DESC

  spec.homepage    = "https://activeagents.ai"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 4.0.0" # Requires Ruby 4.0+ for Ractor improvements

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/activeagents/ragents/issues",
    "documentation_uri" => "https://github.com/activeagents/ragents",
    "source_code_uri" => "https://github.com/activeagents/ragents",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["CHANGELOG.md", "README.md", "MIT-LICENSE", "lib/**/*"]
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "ruby_llm", ">= 1.0"

  # Development dependencies
  spec.add_development_dependency "bundler", ">= 2.0"
  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "webmock", ">= 3.0"
end
