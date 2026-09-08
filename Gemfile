source "https://rubygems.org"

gem "rails", "~> 8.1.2"
gem "propshaft"
gem "sqlite3", ">= 2.1"
gem "puma", "~> 7.2.1"
gem "json", "~> 2.19.9"
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

# Error tracking (no-op when SENTRY_DSN is unset)
gem "sentry-ruby"
gem "sentry-rails"

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "brakeman", require: false
  # Audits Gemfile.lock against the ruby-advisory-db. bin/bundler-audit (run by
  # CI's scan_ruby job) requires this gem; it was previously referenced but not
  # declared, so the CI gem-vulnerability scan failed to load.
  gem "bundler-audit", require: false
  gem "rubocop-rails-omakase", require: false
end

group :test do
  gem "webmock", require: false
  gem "simplecov", require: false
end

group :development do
  gem "web-console"
end
