require_relative "lib/ragents/version"

Gem::Specification.new do |spec|
  spec.name        = "ragents"

  spec.version     = Ragents::VERSION
  spec.authors     = [ "Justin Bowen" ]
  spec.email       = [ "JusBowen@gmail.com" ]
  spec.summary     = "A Rails engine for managing prompts in ActiveAgents."
  spec.description = "Ragents is a Rails engine that provides a user interface for managing prompts"
  spec.authors = [ "Justin Bowen" ]
  spec.email = "jusbowen@gmail.com"
  spec.files = Dir["CHANGELOG.md", "README.rdoc", "MIT-LICENSE", "lib/**/*"]
  spec.require_paths = "lib"
  spec.homepage = "https://activeagents.ai"
  spec.license = "MIT"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/activeagents/activeagent/issues",
    "documentation_uri" => "https://github.com/activeagents/activeagent",
    "source_code_uri" => "https://github.com/activeagents/activeagent",
    "rubygems_mfa_required" => "true"
  }

  spec.add_dependency "rails", ">= 8.0.2"
end

