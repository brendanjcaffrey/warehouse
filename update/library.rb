# frozen_string_literal: true

require 'tmpdir'
require 'tempfile'
require 'json'
require_relative 'pretty_on_failure'
require_relative 'embedded_lyrics'

module Update
  class Library
    GET_PLAYED_COUNT = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        played count of thisTrack as string
      end tell
    SCRIPT

    INCREMENT_PLAYED_COUNT = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        set played count of thisTrack to (played count of thisTrack) + 1
      end tell
    SCRIPT

    GET_TEMPLATE = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        %s of thisTrack
      end tell
    SCRIPT

    UPDATE_TEMPLATE = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        set %s of thisTrack to %s
      end tell
    SCRIPT

    GET_RATING = format(GET_TEMPLATE, '%s', 'rating')
    GET_NAME = format(GET_TEMPLATE, '%s', 'name')
    GET_ARTIST = format(GET_TEMPLATE, '%s', 'artist')
    GET_ALBUM = format(GET_TEMPLATE, '%s', 'album')
    GET_ALBUM_ARTIST = format(GET_TEMPLATE, '%s', 'album artist')
    GET_GENRE = format(GET_TEMPLATE, '%s', 'genre')
    GET_YEAR = format(GET_TEMPLATE, '%s', 'year')
    GET_START = format(GET_TEMPLATE, '%s', 'start')
    GET_FINISH = format(GET_TEMPLATE, '%s', 'finish')
    UPDATE_RATING = format(UPDATE_TEMPLATE, '%s', 'rating', '%s')
    UPDATE_NAME = format(UPDATE_TEMPLATE, '%s', 'name', '"%s"')
    UPDATE_ARTIST = format(UPDATE_TEMPLATE, '%s', 'artist', '"%s"')
    UPDATE_ALBUM = format(UPDATE_TEMPLATE, '%s', 'album', '"%s"')
    UPDATE_ALBUM_ARTIST = format(UPDATE_TEMPLATE, '%s', 'album artist', '"%s"')
    UPDATE_GENRE = format(UPDATE_TEMPLATE, '%s', 'genre', '"%s"')
    UPDATE_YEAR = format(UPDATE_TEMPLATE, '%s', 'year', '%s')
    UPDATE_START = format(UPDATE_TEMPLATE, '%s', 'start', '%s')
    UPDATE_FINISH = format(UPDATE_TEMPLATE, '%s', 'finish', '%s')

    # jxa keeps json text out of applescript's string coercion, which drops a leading bom.
    UPDATE_TEXT_TEMPLATE = <<~SCRIPT
      ObjC.import('Foundation');
      function run(argv) {
        var data = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
        var request = JSON.parse(ObjC.unwrap(data));
        var music = Application('Music');
        var track = music.fileTracks.whose({persistentID: request.track_id})[0];
        if (request.refresh) music.refresh(track);
        track.%<field>s = request.value;
        return JSON.stringify(track.%<field>s());
      }
    SCRIPT

    UPDATE_LYRICS = format(UPDATE_TEXT_TEMPLATE, field: 'lyrics')
    UPDATE_COMMENTS = format(UPDATE_TEXT_TEMPLATE, field: 'comment')

    GET_LYRICS_FILE = <<~SCRIPT
      function run(argv) {
        var track = Application('Music').fileTracks.whose({persistentID: argv[0]})[0];
        return JSON.stringify({track_id: track.persistentID(), path: track.location().toString(), lyrics: track.lyrics()});
      }
    SCRIPT

    GET_ARTWORK = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        set artworkDir to "%s"
        repeat with thisArtwork in artworks of thisTrack
            set fileName to (artworkDir & (persistent ID of thisTrack as string))
            try
              set outFile to open for access fileName with write permission
              set srcBytes to raw data of thisArtwork
              set eof outFile to 0
              write srcBytes to outFile

              close access fileName
              exit repeat
            on error
              close access fileName
            end try
        end repeat
      end tell
    SCRIPT

    CLEAR_ARTWORK = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        repeat while count of artworks of thisTrack > 0
          delete artwork 1 of thisTrack
        end repeat
      end tell
    SCRIPT

    SET_ARTWORK = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        set artworkFilePath to "%s"

        set artworkFile to POSIX file artworkFilePath as alias
        set fileRef to (open for access artworkFile)
        set artworkData to (read fileRef as picture)
        close access fileRef

        set data of artwork 1 of thisTrack to artworkData
      end tell
    SCRIPT

    def initialize
      @command = TTY::Command.new(printer: PrettyOnFailure)
    end

    def get_plays(persistent_id)
      @command.run("osascript -e '#{GET_PLAYED_COUNT % escape(persistent_id)}'").out.chomp
    end

    def add_play(persistent_id)
      start_count = get_plays(persistent_id)
      @command.run("osascript -e '#{INCREMENT_PLAYED_COUNT % escape(persistent_id)}'")
      end_count = get_plays(persistent_id)
      puts "#{start_count} -> #{end_count}"
    end

    def get_rating(persistent_id)
      @command.run("osascript -e '#{GET_RATING % escape(persistent_id)}'").out.chomp
    end

    def update_rating(persistent_id, new_rating)
      start_rating = get_rating(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_RATING, escape(persistent_id), new_rating.to_i)}'")
      end_rating = get_rating(persistent_id)
      puts "#{start_rating} -> #{end_rating}"
    end

    def get_name(persistent_id)
      @command.run("osascript -e '#{GET_NAME % escape(persistent_id)}'").out.chomp
    end

    def update_name(persistent_id, new_name)
      start_name = get_name(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_NAME, escape(persistent_id), escape(new_name))}'")
      end_name = get_name(persistent_id)
      puts "#{start_name} -> #{end_name}"
    end

    def get_artist(persistent_id)
      @command.run("osascript -e '#{GET_ARTIST % escape(persistent_id)}'").out.chomp
    end

    def update_artist(persistent_id, new_artist)
      start_artist = get_artist(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_ARTIST, escape(persistent_id), escape(new_artist))}'")
      end_artist = get_artist(persistent_id)
      puts "#{start_artist} -> #{end_artist}"
    end

    def get_album(persistent_id)
      @command.run("osascript -e '#{GET_ALBUM % escape(persistent_id)}'").out.chomp
    end

    def update_album(persistent_id, new_album)
      start_album = get_album(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_ALBUM, escape(persistent_id), escape(new_album))}'")
      end_album = get_album(persistent_id)
      puts "#{start_album} -> #{end_album}"
    end

    def get_album_artist(persistent_id)
      @command.run("osascript -e '#{GET_ALBUM_ARTIST % escape(persistent_id)}'").out.chomp
    end

    def update_album_artist(persistent_id, new_album_artist)
      start_album_artist = get_album_artist(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_ALBUM_ARTIST, escape(persistent_id), escape(new_album_artist))}'")
      end_album_artist = get_album_artist(persistent_id)
      puts "#{start_album_artist} -> #{end_album_artist}"
    end

    def get_genre(persistent_id)
      @command.run("osascript -e '#{GET_GENRE % escape(persistent_id)}'").out.chomp
    end

    def update_genre(persistent_id, new_genre)
      start_genre = get_genre(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_GENRE, escape(persistent_id), escape(new_genre))}'")
      end_genre = get_genre(persistent_id)
      puts "#{start_genre} -> #{end_genre}"
    end

    def get_year(persistent_id)
      @command.run("osascript -e '#{GET_YEAR % escape(persistent_id)}'").out.chomp
    end

    def update_year(persistent_id, new_year)
      start_year = get_year(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_YEAR, escape(persistent_id), new_year.to_i)}'")
      end_year = get_year(persistent_id)
      puts "#{start_year} -> #{end_year}"
    end

    def get_start(persistent_id)
      @command.run("osascript -e '#{GET_START % escape(persistent_id)}'").out.chomp
    end

    def update_start(persistent_id, new_start)
      start_start = get_start(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_START, escape(persistent_id), new_start.to_f)}'")
      end_start = get_start(persistent_id)
      puts "#{start_start} -> #{end_start}"
    end

    def get_finish(persistent_id)
      @command.run("osascript -e '#{GET_FINISH % escape(persistent_id)}'").out.chomp
    end

    def update_finish(persistent_id, new_finish)
      start_finish = get_finish(persistent_id)
      @command.run("osascript -e '#{format(UPDATE_FINISH, escape(persistent_id), new_finish.to_f)}'")
      end_finish = get_finish(persistent_id)
      puts "#{start_finish} -> #{end_finish}"
    end

    def update_lyrics(persistent_id, new_lyrics)
      update_text(persistent_id, new_lyrics, UPDATE_LYRICS, 'lyrics')
    end

    def update_comments(persistent_id, new_comments)
      update_text(persistent_id, new_comments, UPDATE_COMMENTS, 'comments')
    end

    def get_artwork(persistent_id)
      @command.run!("osascript -e '#{format(GET_ARTWORK, persistent_id, "#{@tmpdir}/")}'")
      artwork_filename = "#{@tmpdir}/#{persistent_id}"
      artwork_size = File.size?(artwork_filename)
      return 'nil' unless artwork_size

      md5 = Digest::MD5.file(artwork_filename).hexdigest
      type = get_artwork_type(artwork_filename)
      FileUtils.rm_f(artwork_filename)
      "#{md5}.#{type}"
    end

    def update_artwork(persistent_id, new_artwork)
      start_artwork = get_artwork(persistent_id)
      @command.run("osascript -e '#{format(CLEAR_ARTWORK, escape(persistent_id))}'")
      if new_artwork && new_artwork != ''
        artwork_filepath = File.join(@artwork_dir, new_artwork)
        raise "Artwork file '#{artwork_filepath}' does not exist" unless File.exist?(artwork_filepath)

        @command.run("osascript -e '#{format(SET_ARTWORK, escape(persistent_id), escape(artwork_filepath))}'")
      end

      end_artwork = get_artwork(persistent_id)
      puts "#{start_artwork} -> #{end_artwork}"
    end

    def update_text(persistent_id, value, script, field)
      saved_text = write_text(persistent_id, value, script)
      if field == 'lyrics' && value == '' && saved_text.is_a?(String) && !saved_text.empty?
        result = @command.run('osascript', '-l', 'JavaScript', '-e', GET_LYRICS_FILE, persistent_id)
        info = JSON.parse(result.out)
        raise 'music track changed before embedded lyrics repair' unless info['track_id'] == persistent_id && info['lyrics'] == saved_text && info['path'].is_a?(String) && info['path'].start_with?('/')

        backup = EmbeddedLyrics.clear(info['path'])
        if backup
          puts "backed up music file to #{backup}"
          saved_text = write_text(persistent_id, value, script, refresh: true)
        end
      end
      raise 'music text read-back does not match the queued value' unless saved_text == value

      puts "updated #{field}"
      saved_text
    end
    private :update_text

    def write_text(persistent_id, value, script, refresh: false)
      Tempfile.create(['warehouse-track-text', '.json']) do |request|
        data = { track_id: persistent_id, value: value }
        data[:refresh] = true if refresh
        request.write(JSON.generate(data))
        request.flush
        result = @command.run('osascript', '-l', 'JavaScript', '-e', script, request.path)
        JSON.parse(result.out)
      end
    end
    private :write_text

    def escape(str)
      str.gsub('"', '\"').gsub("'", "'\"'\"'")
    end
  end
end
