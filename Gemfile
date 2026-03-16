source "https://rubygems.org"

gem "rails", "~> 8.1.2"
gem "propshaft"
gem "sqlite3", ">= 2.1"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "solid_queue"
gem "bootsnap", require: false
gem "thruster", require: false
gem "tzinfo-data", platforms: %i[windows jruby]

# Auth
gem "devise"

# HTTP clients
gem "httparty"

# Admin dashboard charts
gem "chartkick"
gem "groupdate"

# Phone number normalization
gem "phonelib"

# Rate limiting
gem "rack-attack"

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end
