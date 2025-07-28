require 'rubygems'
require 'require_all'
require 'rspec/core/rake_task'
require 'sinatra'
require 'tty-command'
require_relative 'shared/config'

command = TTY::Command.new

namespace :export do
  desc 'export tracks via the Warehouse Export app'
  task :run do
    task_name = Rake.application.top_level_tasks.first
    extra_args = task_name.include?('fast') ? ' --fast' : ''

    parent_dir = File.expand_path('~/Library/Developer/Xcode/DerivedData/')
    prefix = 'warehouse-export-*'
    globs = Dir.glob(File.join(parent_dir, prefix))
    if globs.empty?
      warn "Unable to find any warehouse-export builds in #{parent_dir}, did you build the export app in Xcode?"
      exit(1)
    elsif globs.size > 1
      warn "Multiple warehouse-export builds in #{parent_dir}, try deleting all and rebuilding!\n#{globs.join("\n")}"
      exit(1)
    end

    app = File.join(globs.first, 'Build/Products/Debug/Warehouse Export.app')
    unless File.exist?(app)
      warn "Unable to find the Warehouse Export app in #{globs.first}, did you build the export app in Xcode?"
      exit(1)
    end

    outfile = "#{__dir__}/export.log"
    if File.exist?(outfile)
      File.truncate(outfile, 0)
    else
      FileUtils.touch(outfile)
    end
    puts "Running Warehouse Export app at #{app} with output in #{outfile}..."
    puts `open -a "#{app}" --args --headless --log "#{outfile}"#{extra_args}`

    last_outfile_mod = File.mtime(outfile)
    no_changes_count = 0
    loop do
      no_changes = true
      new_outfile_mod = File.mtime(outfile)
      if last_outfile_mod != new_outfile_mod
        last_outfile_mod = new_outfile_mod
        no_changes = false
        contents = File.read(outfile)
        if contents.include?('Export finished successfully')
          puts(contents.lines.reject { _1.include?('tracks processed:') })
          exit(0)
        elsif contents.include?('Failed to export')
          warn 'Export failed!'
          puts contents
          exit(1)
        else
          puts contents.lines[-1].chomp
        end
      end

      if no_changes
        no_changes_count += 1
        if no_changes_count > 10
          warn 'no log changes in 10 seconds. it probably crashed?'
          puts File.read(outfile)
          exit(1)
        end
      else
        no_changes_count = 0
      end
      sleep(2.5)
    end
  end

  desc 'fast export tracks via the Warehouse Export app'
  task :fast do
    Rake::Task['export:run'].invoke
  end
end

desc 'update iTunes library with any changes in the database'
task :update do
  Config.set_env('local')
  require_all 'update'

  database = Update::Database.new(Config.env.database_username, Config.env.database_password, Config.env.database_name)
  library = Update::Library.new
  Update::Updater.new(database, library).update_library!
end

desc 'compile the protobuf definitions'
task :proto do
  command.run('protoc --ruby_out=./shared messages.proto')
  command.run('protoc --plugin="protoc-gen-ts=./web/node_modules/.bin/protoc-gen-ts" --ts_out="./web/src/generated" ./messages.proto')
end

namespace :server do
  desc 'install the server dependencies'
  task :install do
    command.run('bundle')
  end

  desc 'run the server with local config'
  task :local do
    Config.set_env('local')
    require_relative 'server/server'

    Server.run!
  end

  desc 'run the server with remote config'
  task :remote do
    Config.set_env('remote')
    require_relative 'server/server'

    Server.run!
  end

  desc 'run the server specs'
  RSpec::Core::RakeTask.new(:spec) do |t|
    t.pattern = Dir.glob('server/spec/*_spec.rb')
  end
end

namespace :web do
  desc 'install the web dependencies'
  task :install do
    command.run('cd web && npm install')
  end

  desc 'build the web app for distribution'
  task build: %i[web:install proto] do
    command.run('cd web && npm run build')
  end

  desc 'run the web app in development mode'
  task :vite do
    Dir.chdir('web') do
      exec('node_modules/.bin/vite')
    end
  end

  desc 'run the web tests'
  task :vitest do
    Dir.chdir('web') do
      exec('npx vitest')
    end
  end
end

namespace :changes do
  desc 'archive the database with today\'s date'
  task :archive do
    command.run('cd changes && ruby archive.rb')
  end

  desc 'diff the two newest archives'
  task :diff do
    command.run('cd changes && ruby diff.rb')
  end

  desc 'print out the most played tracks this year by diffing the latest archive with the first archive from this calendar year'
  task :rewind do
    command.run('cd changes && ruby rewind.rb')
  end
end

desc 'run linting and formatting checks'
task :checks do
  command.run('bundle exec rubocop Rakefile server/ shared/ update/ changes/')
end
