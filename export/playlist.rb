module Export
  Playlist = Struct.new(:id, :name, :special_kind, :parent_id, :track_count, :track_string) do
    def tracks
      @tracks ||= (track_string.nil? ? [] : track_string.split("\n"))
    end

    def is_library
      special_kind == 'Music' ? 1 : 0
    end

    def skip?
      special_kind != 'Music' && special_kind != 'none'
    end
  end
end
