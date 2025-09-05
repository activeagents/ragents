require_relative "lib/ragents/version"

Gem::Specification.new do |spec|
  spec.name        = "ragents"
  spec.version     = Ragents::VERSION
  spec.authors     = [ "Justin Bowen" ]
  spec.email       = [ "JusBowen@gmail.com" ]
  spec.homepage    = "https://activeagents.ai"
  spec.summary     = "cats: Summary of Ragents."
  spec.description = "cats: Description of Ragents."
  spec.license     = "MIT"



  spec.metadata["homepage_uri"] = spec.homepage
  
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0.2.1"
end
