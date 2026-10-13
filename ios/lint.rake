namespace :ios do
  desc 'run strict swiftlint checks for ios and watch sources and tests'
  task :lint do
    sh File.expand_path('../check_swiftlint.sh', __dir__)
  end
end
