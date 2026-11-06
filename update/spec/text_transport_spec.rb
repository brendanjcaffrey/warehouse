require 'rspec'
require_relative '../library'

RSpec.describe 'music text transport' do
  let(:library) { Update::Library.new }
  let(:track_id) { '0123456789ABCDEF' }
  let(:text) { "\uFEFFcafe\u0301 雪 🎵\r\nO'Brien says \"hello\" \\path \\n\n$(echo injected); `id`\n\n" }
  let(:music_stub) do
    <<~SCRIPT
      var fakeMusicApplication = function(name) {
        if (name !== 'Music') throw new Error('unexpected application');
        var values = {lyrics: 'original lyrics', comment: 'original comments'};
        var track = {};
        ['lyrics', 'comment'].forEach(function(field) {
          Object.defineProperty(track, field, {
            set: function(value) { values[field] = value; },
            get: function() { return function() {
              var other = field === 'lyrics' ? 'comment' : 'lyrics';
              var expected = other === 'lyrics' ? 'original lyrics' : 'original comments';
              if (values[other] !== expected) throw new Error('unrelated field changed');
              return values[field];
            }; }
          });
        });
        return {fileTracks: {whose: function(filter) {
          if (filter.persistentID !== '0123456789ABCDEF') throw new Error('wrong track');
          return [track];
        }}};
      };
    SCRIPT
  end

  %w[lyrics comments].each do |field|
    it "round trips #{field} through real osascript with music replaced by an in-memory stub" do
      skip 'requires macos javascript for automation' unless RUBY_PLATFORM.include?('darwin')

      constant = "Update::Library::UPDATE_#{field.upcase}"
      script = <<~SCRIPT
        #{music_stub}
        var productionRun = (function(Application) {
          if (Application !== fakeMusicApplication) throw new Error('music stub unavailable');
          #{Update::Library.const_get("UPDATE_#{field.upcase}")}
          return run;
        })(fakeMusicApplication);
        function run(argv) { return productionRun(argv); }
      SCRIPT
      stub_const(constant, script)
      allow($stdout).to receive(:puts)

      ['', text, text * 20_000].each do |value|
        expect(library.public_send("update_#{field}", track_id, value).bytes).to eq(value.bytes)
      end
    end
  end

  it 'clears a stale embedded lyrics tag through the real interpreter, file repair and refresh path' do
    skip 'requires macos javascript for automation' unless RUBY_PLATFORM.include?('darwin')

    Dir.mktmpdir('warehouse-lyrics-recovery') do |dir|
      path = File.join(dir, 'track.mp3')
      frame = 'USLT'.b + [0, 0, 0, 21, 0, 0].pack('C*') + "\0XXX\0rockdizmusic.com".b
      original = 'ID3'.b + [4, 0, 0, 0, 0, 0, frame.bytesize].pack('C*') + frame + 'audio'.b
      repaired = "#{original.byteslice(0, 10)}#{"\0" * frame.bytesize}audio"
      repaired_base64 = [repaired].pack('m0')
      File.binwrite(path, original)
      fake_music = <<~SCRIPT
        ObjC.import('Foundation');
        var fakeMusicApplication = function(name) {
          if (name !== 'Music') throw new Error('unexpected application');
          var saved = 'rockdizmusic.com';
          var track = {
            persistentID: function() { return '0123456789ABCDEF'; },
            location: function() { return #{JSON.generate(path)}; }
          };
          Object.defineProperty(track, 'lyrics', {
            set: function(value) {
              if (value !== '') throw new Error('expected lyrics clear');
            },
            get: function() { return function() { return saved; }; }
          });
          return {
            fileTracks: {whose: function(filter) {
              if (filter.persistentID !== track.persistentID()) throw new Error('wrong track');
              return [track];
            }},
            refresh: function(refreshedTrack) {
              if (refreshedTrack !== track) throw new Error('wrong refresh target');
              var data = $.NSData.dataWithContentsOfFile(#{JSON.generate(path)});
              var bytes = ObjC.unwrap(data.base64EncodedStringWithOptions(0));
              if (bytes !== #{JSON.generate(repaired_base64)}) {
                throw new Error('file repair changed other bytes');
              }
              saved = '';
            }
          };
        };
      SCRIPT
      %w[UPDATE_LYRICS GET_LYRICS_FILE].each do |constant|
        production = Update::Library.const_get(constant)
        script = <<~SCRIPT
          #{fake_music}
          var productionRun = (function(Application) {
            #{production}
            return run;
          })(fakeMusicApplication);
          function run(argv) { return productionRun(argv); }
        SCRIPT
        stub_const("Update::Library::#{constant}", script)
      end

      expect { expect(library.update_lyrics(track_id, '')).to eq('') }.to output(/updated lyrics/).to_stdout
      backup = Dir.glob(File.join(dir, '.warehouse-lyrics-*.bak')).fetch(0)
      expect(File.binread(backup)).to eq(original)
      expect(File.binread(path).byteslice(-5, 5)).to eq('audio')
    end
  end
end
