# frozen_string_literal: true

require 'tempfile'

module Update
  class EmbeddedLyrics
    MAX_TAG_SIZE = 64 * 1024 * 1024

    def self.clear(path)
      return unless File.extname(path).downcase == '.mp3'

      File.open(path, 'r+b') do |file|
        raise 'could not lock music file for embedded lyrics repair' unless file.flock(File::LOCK_EX | File::LOCK_NB)

        header = file.read(10)
        next unless header&.bytesize == 10 && header.start_with?('ID3') && [3, 4].include?(header.getbyte(3)) && header.byteslice(4, 2) == "\0\0"

        size = synchsafe(header.byteslice(6, 4))
        raise 'invalid id3 tag size' if size > MAX_TAG_SIZE || size > file.stat.size - 10

        tag = file.read(size)
        replacement = without_lyrics(tag, header.getbyte(3))
        next unless replacement

        backup = back_up(file, header + tag)
        begin
          file.seek(10)
          file.write(replacement)
          file.flush
          file.fsync
          file.rewind
          raise 'embedded lyrics repair verification failed' unless file.read(10 + size) == header + replacement
        rescue StandardError
          file.seek(10)
          file.write(tag)
          file.flush
          file.fsync
          raise
        end
        backup
      end
    end

    def self.synchsafe(bytes)
      raise 'invalid id3 size encoding' unless bytes.bytesize == 4 && bytes.bytes.all? { |byte| byte < 128 }

      bytes.bytes.reduce(0) { |size, byte| (size << 7) | byte }
    end
    private_class_method :synchsafe

    def self.without_lyrics(tag, version)
      kept = String.new(encoding: Encoding::BINARY)
      offset = 0
      removed = false
      while offset < tag.bytesize
        if tag.getbyte(offset).zero?
          raise 'invalid id3 padding' unless tag.byteslice(offset..).bytes.all?(&:zero?)

          break
        end
        header = tag.byteslice(offset, 10)
        raise 'invalid id3 frame header' unless header.bytesize == 10 && header.byteslice(0, 4).match?(/\A[A-Z0-9]{4}\z/)

        size = version == 4 ? synchsafe(header.byteslice(4, 4)) : header.byteslice(4, 4).unpack1('N')
        length = 10 + size
        raise 'invalid id3 frame size' if size.zero? || length > tag.bytesize - offset

        if header.start_with?('USLT')
          removed = true
        else
          kept << tag.byteslice(offset, length)
        end
        offset += length
      end
      kept + ("\0" * (tag.bytesize - kept.bytesize)) if removed
    end
    private_class_method :without_lyrics

    def self.back_up(file, expected_tag)
      stat = file.stat
      backup = Tempfile.create(['.warehouse-lyrics-', '.bak'], File.dirname(file.path))
      begin
        backup.binmode
        file.rewind
        IO.copy_stream(file, backup)
        backup.flush
        backup.fsync
        File.open(File.dirname(file.path), File::RDONLY, &:fsync)
        file.rewind
        current = file.stat
        raise 'music file changed before embedded lyrics repair' unless [current.size, current.mtime, current.ctime] == [stat.size, stat.mtime, stat.ctime] && file.read(expected_tag.bytesize) == expected_tag
      rescue StandardError
        File.unlink(backup.path)
        raise
      ensure
        backup.close
      end
      backup.path
    end
    private_class_method :back_up
  end
end
