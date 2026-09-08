namespace :e2e do
  desc "Run live e2e tests against E2E_AGAINST (must be set explicitly). Set E2E_RUNNER=local for CI/localhost (bin/rails runner instead of docker exec)."
  task :run do
    abort "Set E2E_AGAINST=https://… first" unless ENV["E2E_AGAINST"]
    abort "Set SYNTHETIC_WEBHOOK_TOKEN" unless ENV["SYNTHETIC_WEBHOOK_TOKEN"]
    files = Dir.glob("e2e/*_test.rb").sort
    abort "No test files found under e2e/" if files.empty?
    requires = files.map { |f| "require '#{File.expand_path(f)}'" }.join("; ")
    sh(*[ "ruby", "-Ie2e", "-Ilib", "-e", requires ])
  end
end
