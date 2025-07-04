require 'rubygems'
require 'require_all'
require 'sinatra'
require 'tty-command'
require_relative 'shared/config'

task :run_export do
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
  while true
    no_changes = true
    new_outfile_mod = File.mtime(outfile)
    if last_outfile_mod != new_outfile_mod
      last_outfile_mod = new_outfile_mod
      no_changes = false
      contents = File.read(outfile)
      if contents.include?('Export finished successfully')
        puts(contents.lines.select { !_1.include?('tracks processed:') })
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

task :export do
  Rake::Task['run_export'].invoke
end

task :fast_export do
  Rake::Task['run_export'].invoke
end

task :update_library do
  Config.set_env('local')
  require_all 'update'

  database = Update::Database.new(Config.env.database_username, Config.env.database_password, Config.env.database_name)
  library = Update::Library.new
  Update::Updater.new(database, library).update_library!
end

task :local do
  Config.set_env('local')
  require_relative 'server'

  Server.run!
end

task :remote do
  Config.set_env('remote')
  require_relative 'server'

  Server.run!
end

task :install do
  command = TTY::Command.new
  command.run('bundle')
  command.run('cd web && npm install')
end

task :proto do
  command = TTY::Command.new
  command.run('protoc --ruby_out=./shared messages.proto')
  command.run('protoc --plugin="protoc-gen-ts=./web/node_modules/.bin/protoc-gen-ts" --ts_out="./web/src/generated" ./messages.proto')
end

task build: %i[install proto] do
  command = TTY::Command.new
  command.run('cd web && npm run build')
end

task :vite do
  Dir.chdir('web') do
    exec('node_modules/.bin/vite')
  end
end

task :vitest do
  Dir.chdir('web') do
    exec('npx vitest')
  end
end
