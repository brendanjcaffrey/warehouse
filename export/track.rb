module Export
  ACCEPTABLE_EXTENSIONS = %w[mp3 mp4 m4a aiff aif wav].freeze

  Track = Struct.new(:id, :name, :sort_name_unclean, :artist, :sort_artist_unclean, :album_artist, :sort_album_artist_unclean,
                     :album, :sort_album_unclean, :genre, :year, :duration, :start, :finish, :track_number, :disc_number, :play_count, :rating_raw, :location, :num_artworks) do
    def file
      # location is like "Macintosh HD:Users:Brendan:Music:iTunes:iTunes Music:artist:album:song.mp3"
      # so we turn the : into /, remove the drive name and lop off what the config provides
      location.gsub(':', '/').gsub(%r{^.+?/}, '/').gsub(Config['music_path'], '')
    end

    def track_file_path
      location.gsub(':', '/').gsub(%r{^.+?/}, '/')
    end

    def track_file_size
      File.size(track_file_path)
    end

    def track_file_md5
      Digest::MD5.file(track_file_path).hexdigest
    end

    def sort_name
      value = clean_sort_value(sort_name_unclean.empty? ? name : sort_name_unclean)
      value != name ? value : ''
    end

    def sort_artist
      value = clean_sort_value(sort_artist_unclean || artist)
      value != album ? value : ''
    end

    def sort_album_artist
      value = clean_sort_value(sort_album_artist_unclean || album_artist)
      value != album_artist ? value : ''
    end

    def sort_album
      value = clean_sort_value(sort_album_unclean || album)
      value != album ? value : ''
    end

    def rating
      rating_raw == '1' ? '0' : rating_raw
    end

    def ext
      file.split('.').last.downcase
    end

    def valid_extension?
      ACCEPTABLE_EXTENSIONS.index(ext) != nil
    end

    def artworks
      @artworks || []
    end

    def add_artwork(filename)
      @artworks ||= []
      @artworks << filename
    end

    private

    def clean_sort_value(value)
      # remove anything that isn't alphanumeric (except 0?)
      # TODO e.g. '03 Bonnie & Clyde sorting as 3, I think it's just nat sorting if it starts with a number, but this works for now
      value.gsub(/^[^a-zA-Z1-9]+/, '')
    end
  end
end
