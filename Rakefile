require 'require_all'

task :export do
  require_all 'export'

  database = Export::Database.new('export.db')
  library = Export::Library.new
  progress = Export::Progress.new
  Export::Driver.new(database, library, progress).go!
end
