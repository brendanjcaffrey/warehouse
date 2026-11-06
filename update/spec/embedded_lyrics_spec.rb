require 'rspec'
require 'tmpdir'
require_relative '../embedded_lyrics'

RSpec.describe 'embedded mp3 lyrics' do
  let(:directory) { Dir.mktmpdir('warehouse-embedded-lyrics') }
  let(:path) { File.join(directory, 'track.mp3') }

  after { FileUtils.remove_entry(directory) }

  def synchsafe(size)
    [21, 14, 7, 0].map { |shift| (size >> shift) & 127 }.pack('C*')
  end

  def frame(name, value, version)
    size = version == 4 ? synchsafe(value.bytesize) : [value.bytesize].pack('N')
    name.b + size + "\0\0".b + value.b
  end

  def mp3(version, frames, padding: 32)
    tag = frames.join.b + ("\0".b * padding)
    'ID3'.b + [version, 0, 0].pack('C*') + synchsafe(tag.bytesize) + tag + "\xff\xfbunchanged audio\0TAGtrailing metadata".b
  end

  [3, 4].each do |version|
    it "removes all id3v2.#{version} lyrics frames with a durable exact backup and preserves every other byte" do
      title = frame('TIT2', "\0title", version)
      artwork = frame('APIC', "\0artwork" * 50, version)
      comment = frame('COMM', "\0eng\0notes", version)
      lyrics = [frame('USLT', "\0XXX\0rockdizmusic.com", version), frame('USLT', "\3eng\0other lyrics", version)]
      original = mp3(version, [title, lyrics.first, artwork, lyrics.last, comment])
      File.binwrite(path, original)
      File.chmod(0o640, path)
      inode = File.stat(path).ino

      backup = Update::EmbeddedLyrics.clear(path)

      expect(File.binread(backup)).to eq(original)
      expected = mp3(version, [title, artwork, comment], padding: 32 + lyrics.sum(&:bytesize))
      expect(File.binread(path)).to eq(expected)
      expect(File.stat(path).ino).to eq(inode)
      expect(File.stat(path).mode & 0o777).to eq(0o640)
      expect(File.stat(backup).mode & 0o777).to eq(0o600)
      expect(Update::EmbeddedLyrics.clear(path)).to be_nil
      expect(Dir.children(File.dirname(path)).size).to eq(2)
    end
  end

  it 'leaves a file without embedded lyrics unchanged and makes no backup' do
    original = mp3(4, [frame('TIT2', "\0title", 4)])
    File.binwrite(path, original)

    expect(Update::EmbeddedLyrics.clear(path)).to be_nil
    expect(File.binread(path)).to eq(original)
    expect(Dir.children(File.dirname(path))).to eq(['track.mp3'])
  end

  it 'declines unsupported formats and header flags without changing the file' do
    original = mp3(4, [frame('USLT', "\0XXX\0lyrics", 4)])
    variants = ['not an mp3'.b, original.dup.tap { |data| data.setbyte(3, 2) }, original.dup.tap { |data| data.setbyte(5, 64) }]
    variants.each do |data|
      File.binwrite(path, data)
      expect(Update::EmbeddedLyrics.clear(path)).to be_nil
      expect(File.binread(path)).to eq(data)
      expect(Dir.children(File.dirname(path))).to eq(['track.mp3'])
    end
  end

  it 'refuses truncated frames and nonzero padding before creating a backup or writing' do
    original = mp3(4, [frame('USLT', "\0XXX\0lyrics", 4)])
    variants = [original.byteslice(0, 20), original.dup.tap { |data| data[14, 4] = synchsafe(1_000_000) },
                original.dup.tap { |data| data.setbyte(35, 1) }]
    variants.each do |data|
      File.binwrite(path, data)
      expect { Update::EmbeddedLyrics.clear(path) }.to raise_error(/invalid id3/)
      expect(File.binread(path)).to eq(data)
      expect(Dir.children(File.dirname(path))).to eq(['track.mp3'])
    end
  end

  it 'does not touch a non-mp3 file even if its bytes start with an id3 tag' do
    other_path = path.sub('.mp3', '.m4a')
    original = mp3(4, [frame('USLT', "\0XXX\0lyrics", 4)])
    File.binwrite(other_path, original)

    expect(Update::EmbeddedLyrics.clear(other_path)).to be_nil
    expect(File.binread(other_path)).to eq(original)
  end

  it 'leaves the source untouched if its backup cannot be made' do
    original = mp3(4, [frame('USLT', "\0XXX\0lyrics", 4)])
    File.binwrite(path, original)
    allow(IO).to receive(:copy_stream).and_raise(Errno::ENOSPC)

    expect { Update::EmbeddedLyrics.clear(path) }.to raise_error(Errno::ENOSPC)
    expect(File.binread(path)).to eq(original)
    expect(Dir.children(File.dirname(path))).to eq(['track.mp3'])
  end

  it 'refuses to overwrite a tag changed while the backup is being copied' do
    original = mp3(4, [frame('USLT', "\0XXX\0lyrics", 4)])
    changed = original.sub('lyrics', 'edited')
    File.binwrite(path, original)
    allow(IO).to receive(:copy_stream).and_wrap_original do |copy, *args|
      result = copy.call(*args)
      File.binwrite(path, changed)
      result
    end

    expect { Update::EmbeddedLyrics.clear(path) }.to raise_error('music file changed before embedded lyrics repair')
    expect(File.binread(path)).to eq(changed)
    expect(Dir.children(File.dirname(path))).to eq(['track.mp3'])
  end

  it 'restores the original tag after a partial write failure and retains the backup' do
    original = mp3(4, [frame('USLT', "\0XXX\0lyrics", 4)])
    File.binwrite(path, original)
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(path, 'r+b').and_wrap_original do |open, *args, &block|
      open.call(*args) do |file|
        attempts = 0
        allow(file).to receive(:write).and_wrap_original do |write, bytes|
          attempts += 1
          if attempts == 1
            write.call(bytes.byteslice(0, 5))
            raise IOError, 'write failed'
          end
          write.call(bytes)
        end
        block.call(file)
      end
    end

    expect { Update::EmbeddedLyrics.clear(path) }.to raise_error('write failed')
    expect(File.binread(path)).to eq(original)
    backup = Dir.glob(File.join(File.dirname(path), '.warehouse-lyrics-*.bak')).fetch(0)
    expect(File.binread(backup)).to eq(original)
  end
end
