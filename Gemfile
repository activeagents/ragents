source "https://rubygems.org"

# Specify gem's dependencies in ragents.gemspec
gemspec

group :development, :test do
  gem "rubocop", require: false
  gem "rubocop-minitest", require: false
  gem "debug", ">= 1.0.0"
end

# Optional provider gems (for testing)
group :test do
  gem "vcr"
end
