require 'rubygems'
require 'require_all'
require 'rspec/core/rake_task'
require 'sinatra'
require 'tty-command'
require_relative 'shared/config'

ROOT = __dir__
SIMULATOR = 'iPhone 17'.freeze
# gitignored derived-data dir the export app builds into, kept in-repo instead
# of the shared ~/Library DerivedData so the build is self-contained.
EXPORT_BUILD_DIR = "#{__dir__}/export/build".freeze
EXPORT_APP = "#{EXPORT_BUILD_DIR}/Build/Products/Release/Warehouse Export.app".freeze
command = TTY::Command.new

# launch the export app headless and tail its log until it reports success or
# failure. shared by export:run (which builds first) and export:run_prebuilt.
def run_export_app
  extra_args = Rake.application.top_level_tasks.any? { _1.include?('fast') } ? ' --fast' : ''

  unless File.exist?(EXPORT_APP)
    warn "Unable to find the Warehouse Export app at #{EXPORT_APP}, did `rake export:build` succeed?"
    exit(1)
  end

  # arm64 refuses to exec an unsigned binary, and launchd reports that as an
  # opaque "Launch failed"/RBSRequestErrorDomain Code=5. a build from a session
  # without an unlocked login keychain (ssh, cron) relinks the binary and then
  # dies at the codesign step, leaving exactly that unsigned bundle behind, so
  # check the signature up front and say what actually needs to happen.
  unless system('codesign', '--verify', EXPORT_APP, out: File::NULL, err: File::NULL)
    warn "The Warehouse Export app at #{EXPORT_APP} isn't validly signed, so macos won't launch it."
    warn 'Run `rake export:build` from a local terminal (not ssh/cron) to rebuild and sign it.'
    exit(1)
  end

  outfile = "#{ROOT}/export.log"
  if File.exist?(outfile)
    File.truncate(outfile, 0)
  else
    FileUtils.touch(outfile)
  end
  puts "Running Warehouse Export app at #{EXPORT_APP} with output in #{outfile}..."
  puts `open -a "#{EXPORT_APP}" --args --headless --log "#{outfile}"#{extra_args}`

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

namespace :export do
  desc 'build the macos Warehouse Export app'
  task :build do
    sh "xcodebuild -project #{ROOT}/export/warehouse-export.xcodeproj " \
       '-scheme warehouse-export ' \
       "-destination 'platform=macOS' " \
       '-configuration Release ' \
       "-derivedDataPath #{EXPORT_BUILD_DIR} " \
       'build'
  end

  # the headless export reads a persisted workspace-dir bookmark and the
  # macos music-library (tcc) grant, neither of which it can establish itself.
  # launch the ui once to pick the workspace dir and grant music access; both
  # persist, so `rake export:run` works headless afterwards.
  desc 'launch the Warehouse Export app ui for first-run setup (pick workspace dir, grant music access)'
  task setup: :build do
    sh %(open -a "#{EXPORT_APP}")
  end

  desc 'build and run the Warehouse Export app to export tracks'
  task run: :build do
    run_export_app
  end

  # xcodebuild's codesign step needs an unlocked login keychain, which an ssh or
  # cron session doesn't have, so `export:run` fails there on the build. running
  # the already-built app needs no signing, so schedule this instead and rebuild
  # interactively (`rake export:build`) whenever the export sources change.
  desc 'run the already-built Warehouse Export app without rebuilding it (for cron/ssh, where codesigning fails)'
  task :run_prebuilt do
    run_export_app
  end

  desc 'fast export tracks via the Warehouse Export app'
  task :fast do
    Rake::Task['export:run'].invoke
  end

  desc 'fast export tracks via the already-built Warehouse Export app (for cron/ssh)'
  task :fast_prebuilt do
    Rake::Task['export:run_prebuilt'].invoke
  end

  desc 'regenerate the macOS Warehouse Export app icon from logo.svg (needs librsvg + imagemagick)'
  task :icons do
    require 'json'
    require 'tmpdir'

    source  = "#{ROOT}/logo.svg"
    iconset = "#{ROOT}/export/export/Assets.xcassets/AppIcon.appiconset"
    abort "missing #{source}" unless File.exist?(source)

    # macOS icons aren't auto-masked like iOS, so the artwork supplies its own
    # rounded tile. the icon grid places an 824pt tile on a 1024 canvas (100pt
    # margin all around for the system drop shadow), corner radius ~185. the
    # glyph is centered on the tile with padding, matching the black-on-white
    # iOS/web icon family.
    tile   = 824
    radius = 185
    Dir.mktmpdir do |tmp|
      # rasterize the vector with librsvg rather than imagemagick's built-in svg
      # renderer: the latter renders the glyph's thin extremities (the bass-clef
      # dots) faintly enough that a later -trim clips them off.
      glyph_png = "#{tmp}/glyph.png"
      command.run('rsvg-convert', '-w', '2048', '-h', '2048', '--keep-aspect-ratio',
                  '--background-color=none', source, '-o', glyph_png)

      master = "#{tmp}/master.png"

      # a subtly gradiented white tile masked to a rounded rectangle, with a
      # faint border so the edge reads against light backgrounds.
      tile_args = [
        '(', '-size', "#{tile}x#{tile}", 'gradient:#fbfcfd-#dfe3e9',
        '(', '-size', "#{tile}x#{tile}", 'xc:none',
        '-draw', "roundrectangle 0,0,#{tile - 1},#{tile - 1},#{radius},#{radius}", ')',
        '-alpha', 'off', '-compose', 'CopyOpacity', '-composite',
        '-fill', 'none', '-stroke', '#c4c9d1', '-strokewidth', '4',
        '-draw', "roundrectangle 2,2,#{tile - 3},#{tile - 3},#{radius - 2},#{radius - 2}", ')'
      ]
      # trim the clean raster to the glyph and size it to leave generous padding.
      glyph_args = ['(', glyph_png, '-trim', '+repage', '-resize', '430x430', ')']
      # composite the glyph centered on the tile, then add a symmetric
      # transparent border (824 -> 1024) to center the tile on the icon canvas
      # with margin for the system drop shadow. (-border centers by construction;
      # -extent with -gravity proved unreliable here.)
      command.run('magick', *tile_args, *glyph_args,
                  '-gravity', 'center', '-compose', 'over', '-composite',
                  '-bordercolor', 'none', '-border', ((1024 - tile) / 2).to_s,
                  "PNG32:#{master}")

      # the macOS appiconset needs 16/32/128/256/512 at 1x and 2x. downscale the
      # single master into each slot rather than re-rendering per size.
      slots = [16, 32, 128, 256, 512].flat_map do |pt|
        %w[1x 2x].map do |scale|
          px     = scale == '2x' ? pt * 2 : pt
          suffix = scale == '2x' ? '@2x' : ''
          { 'size' => "#{pt}x#{pt}", 'idiom' => 'mac', 'scale' => scale,
            'filename' => "export-icon-#{pt}#{suffix}.png", :px => px }
        end
      end

      slots.each do |slot|
        command.run('magick', master, '-resize', "#{slot[:px]}x#{slot[:px]}",
                    '-depth', '8', '-strip', "PNG32:#{iconset}/#{slot['filename']}")
      end

      contents = {
        'images' => slots.map { |slot| slot.except(:px) },
        'info' => { 'author' => 'xcode', 'version' => 1 }
      }
      File.write("#{iconset}/Contents.json", "#{JSON.pretty_generate(contents)}\n")

      # drop any stale pngs from previous icon revisions that the new
      # Contents.json no longer references.
      keep = slots.map { |slot| slot['filename'] }
      Dir.glob("#{iconset}/*.png").each do |file|
        File.delete(file) unless keep.include?(File.basename(file))
      end
    end

    puts "regenerated app icon in #{iconset}"
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
  command.run('protoc --swift_out=./ios/Shared messages.proto')
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

  desc 'expose the server publicly on port 443 via tailscale funnel (proxies to nginx on 20601)'
  task :funnel do
    exec('sudo tailscale funnel --https=443 20601')
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

  desc 'run the web tests once'
  task :vitest do
    Dir.chdir('web') do
      exec('npx vitest run')
    end
  end

  desc 'run the web tests in a watcher'
  task :vitest_watch do
    Dir.chdir('web') do
      exec('npx vitest')
    end
  end

  desc 'run the web browser-mode tests once (needs playwright chromium)'
  task :vitest_browser do
    Dir.chdir('web') do
      exec('npx vitest run --config vitest.browser.config.ts')
    end
  end

  desc 'regenerate the web favicons from logo.svg (needs imagemagick)'
  task :favicon do
    source = "#{ROOT}/logo.svg"
    dest   = "#{ROOT}/web/public/favicon"
    abort "missing #{source}" unless File.exist?(source)

    # rasterize the vector at a high density so curves stay crisp when scaled
    # down, and -background none keeps the source glyph transparent. both must
    # precede the source so they apply during rasterization.
    render = ['magick', '-background', 'none', '-density', '384', source]

    # transparent glyph favicons for browser tabs and the android/pwa icons.
    { 'favicon-16x16.png' => 16, 'favicon-32x32.png' => 32,
      'android-chrome-192x192.png' => 192, 'android-chrome-512x512.png' => 512 }.each do |name, px|
      command.run(*render, '-resize', "#{px}x#{px}",
                  '-depth', '8', '-strip', "PNG32:#{dest}/#{name}")
    end

    # the apple-touch icon shows on the ios home screen, which rejects alpha, so
    # flatten the glyph onto an opaque white background.
    command.run(*render, '-resize', '180x180', '-background', '#ffffff',
                '-flatten', '-alpha', 'off', '-depth', '8', '-strip', "PNG24:#{dest}/apple-touch-icon.png")

    # multi-resolution .ico fallback for legacy browsers.
    command.run(*render, '-define', 'icon:auto-resize=16,32,48', "#{dest}/favicon.ico")

    puts "regenerated favicons in #{dest}"
  end
end

namespace :ios do
  desc 'list the available xcode schemes'
  task :list_schemas do
    sh "xcodebuild -project #{ROOT}/ios/Warehouse.xcodeproj -list"
  end

  desc 'build the iOS app for the simulator'
  task :build do
    sh "xcodebuild -project #{ROOT}/ios/Warehouse.xcodeproj " \
       '-scheme Warehouse ' \
       "-destination 'generic/platform=iOS Simulator' " \
       '-configuration Debug ' \
       'build'
  end

  # `xcodebuild test` needs a concrete, bootable simulator (unlike :build's
  # generic destination). override the device with SIMULATOR=... if the default
  # isn't installed (`xcrun simctl list devices available` to see options).
  desc 'run the iOS unit tests (override the sim with SIMULATOR=...)'
  task :test do
    simulator = ENV.fetch('SIMULATOR', SIMULATOR)
    sh "xcodebuild test -project #{ROOT}/ios/Warehouse.xcodeproj " \
       '-scheme Warehouse ' \
       "-destination 'platform=iOS Simulator,name=#{simulator}' " \
       '-only-testing:WarehouseTests'
  end

  # UI tests launch the app in the simulator and drive it, so they're slower
  # than the unit tests and kept as a separate task.
  desc 'run the iOS UI tests (override the sim with SIMULATOR=...)'
  task :uitest do
    simulator = ENV.fetch('SIMULATOR', SIMULATOR)
    sh "xcodebuild test -project #{ROOT}/ios/Warehouse.xcodeproj " \
       '-scheme Warehouse ' \
       "-destination 'platform=iOS Simulator,name=#{simulator}' " \
       '-only-testing:WarehouseUITests'
  end

  # archive the app and upload it to testflight (internal testers). runs on the
  # host, not in a container (no xcode in the build image), same as :build.
  #
  # requires an app store connect api key. generate one at
  # appstoreconnect.apple.com -> users and access -> integrations -> app store
  # connect api, drop the .p8 at
  # ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8, and export the ids:
  #   ASC_KEY_ID=... ASC_ISSUER_ID=... rake ios:testflight
  desc 'archive the iOS app and upload to testflight (internal testers)'
  task :testflight do
    key_id    = ENV['ASC_KEY_ID'].to_s
    issuer_id = ENV['ASC_ISSUER_ID'].to_s
    abort 'set ASC_KEY_ID and ASC_ISSUER_ID in the environment first' if key_id.empty? || issuer_id.empty?

    archive = "#{ROOT}/ios/build/Warehouse.xcarchive"
    export  = "#{ROOT}/ios/build/export"
    opts    = "#{ROOT}/ios/ExportOptions.plist"

    # unlock the login keychain so codesign can read the signing key
    # (otherwise the archive fails with errSecInternalComponent)
    require 'io/console'
    pw = $stdin.getpass('login keychain password: ')
    sh 'security', 'unlock-keychain', '-p', pw,
       "#{Dir.home}/Library/Keychains/login.keychain-db", verbose: false

    # derive a fresh build number from the unix timestamp so testflight accepts
    # a new upload. passed as a build-setting override so the pbxproj is never
    # mutated (no git diff), and unique per run even between commits.
    build_no = Time.now.to_i

    sh 'xcodebuild archive ' \
       "-project #{ROOT}/ios/Warehouse.xcodeproj " \
       '-scheme Warehouse -configuration Release ' \
       "-destination 'generic/platform=iOS' " \
       "-archivePath #{archive} " \
       "CURRENT_PROJECT_VERSION=#{build_no} " \
       '-allowProvisioningUpdates'

    sh 'xcodebuild -exportArchive ' \
       "-archivePath #{archive} " \
       "-exportPath #{export} " \
       "-exportOptionsPlist #{opts} " \
       '-allowProvisioningUpdates'

    sh "xcrun altool --upload-app -f #{export}/Warehouse.ipa --type ios " \
       "--apiKey #{key_id} --apiIssuer #{issuer_id}"
  end

  desc 'regenerate the iOS app icons from logo.svg (needs imagemagick)'
  task :icons do
    require 'json'

    source  = "#{ROOT}/logo.svg"
    iconset = "#{ROOT}/ios/Warehouse/Assets.xcassets/AppIcon.appiconset"
    abort "missing #{source}" unless File.exist?(source)

    # ios rejects icons with an alpha channel, so every variant is flattened onto
    # an opaque fill. the source glyph is black-on-transparent, so the dark and
    # tinted variants negate the rgb channels to make it white and keep it
    # visible against a dark fill. [negate?, background]
    variants = {
      'logo.png' => [false, '#ffffff'], # light: black glyph on white
      'logo-dark.png' => [true, '#1c1c1e'], # dark:  white glyph on near-black
      'logo-tinted.png' => [true, '#000000'] # tinted: ios applies the user's tint
    }

    variants.each do |name, (negate, bg)|
      # rasterize transparent at a high density (both must precede the source):
      # transparency lets a later negate flip only the glyph, and the opaque
      # fill is applied at flatten time so it isn't negated with it. the glyph
      # is sized to 80% and centered on the 1024 canvas to leave 10% padding.
      args = ['magick', '-background', 'none', '-density', '384', source, '-resize', '819x819']
      args += ['-channel', 'RGB', '-negate', '+channel'] if negate
      args += ['-gravity', 'center', '-background', bg, '-extent', '1024x1024',
               '-flatten', '-alpha', 'off', '-depth', '8', '-strip', "PNG24:#{iconset}/#{name}"]
      command.run(*args)
    end

    # point each appearance slot at its generated file.
    contents_path = "#{iconset}/Contents.json"
    contents = JSON.parse(File.read(contents_path))
    contents['images'].each do |img|
      img['filename'] = case img.dig('appearances', 0, 'value')
                        when 'dark'   then 'logo-dark.png'
                        when 'tinted' then 'logo-tinted.png'
                        else 'logo.png'
                        end
    end
    File.write(contents_path, "#{JSON.pretty_generate(contents)}\n")

    puts "regenerated app icons in #{iconset}"
  end
end

namespace :db do
  desc 'trim the local database down to 100 tracks for development (leaves music/artwork files alone)'
  task :trim do
    require 'pg'
    Config.set_env('local')

    db = PG.connect(user: Config.env.database_username, password: Config.env.database_password,
                    dbname: Config.env.database_name)

    total = db.exec('SELECT COUNT(*) FROM tracks;').getvalue(0, 0).to_i
    if total <= 100
      puts "only #{total} tracks in #{Config.env.database_name}, nothing to trim"
      next
    end

    print "delete #{total - 100} of #{total} tracks from #{Config.env.database_name}? [y/N] "
    abort 'aborted' unless $stdin.gets.to_s.strip.downcase == 'y'

    db.transaction do |conn|
      # keep the most played tracks so the remaining data is still interesting
      conn.exec('DELETE FROM tracks WHERE id NOT IN (SELECT id FROM tracks ORDER BY play_count DESC, id LIMIT 100);')
      conn.exec('DELETE FROM playlist_tracks WHERE track_id NOT IN (SELECT id FROM tracks);')

      # prune rows that referenced the deleted tracks
      %w[plays rating_updates name_updates artist_updates album_updates album_artist_updates
         genre_updates year_updates start_updates finish_updates artwork_updates].each do |table|
        conn.exec("DELETE FROM #{table} WHERE track_id NOT IN (SELECT id FROM tracks);")
      end
      conn.exec(<<~SQL)
        DELETE FROM artists WHERE id NOT IN (
          SELECT artist_id FROM tracks WHERE artist_id IS NOT NULL
          UNION
          SELECT album_artist_id FROM tracks WHERE album_artist_id IS NOT NULL
        );
      SQL
      conn.exec('DELETE FROM albums WHERE id NOT IN (SELECT album_id FROM tracks WHERE album_id IS NOT NULL);')
      conn.exec('DELETE FROM genres WHERE id NOT IN (SELECT genre_id FROM tracks WHERE genre_id IS NOT NULL);')
    end

    %w[track_name_search_view artist_name_search_view album_name_search_view
       genre_name_search_view playlist_name_search_view].each do |view|
      db.exec("REFRESH MATERIALIZED VIEW #{view};")
    end

    puts "trimmed #{Config.env.database_name} to 100 tracks"
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
  # ensure a .rubocop.yml file exists to avoid RuboCop complaining
  FileUtils.touch(File.expand_path('~/.rubocop.yml'))
  command.run('bundle exec rubocop Rakefile server/ shared/ update/ changes/')
  Dir.chdir('web') do
    command.run('npm run lint')
    command.run('npm run format:check')
  end
end
