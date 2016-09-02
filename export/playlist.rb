module Export
  class Playlist < Struct.new(:id, :name, :special_kind, :parent_id, :track_count, :track_string)
    def tracks
      @tracks ||= (track_string.nil? ? [] : track_string.split("\n"))
    end

    def is_library
      special_kind == 'Music' ? 1 : 0
    end
  end
end
