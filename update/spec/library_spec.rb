require 'rspec'
require 'json'
require_relative '../library'

RSpec.describe 'music library text updates' do
  subject(:library) { Update::Library.new }

  let(:command) { instance_double(TTY::Command) }
  let(:track_id) { '0123456789ABCDEF' }
  let(:text) { "\uFEFFcafe\u0301 雪 🎵\r\nO'Brien says \"hello\" \\n \\path\n$(touch /tmp/should-not-exist); `id`\n\n" }

  before do
    allow(TTY::Command).to receive(:new).and_return(command)
    allow(command).to receive(:run).and_raise('unexpected music execution')
  end

  %w[lyrics comments].each do |field|
    describe "#update_#{field}" do
      it 'transports exact text as json data and preserves the read-back line endings' do
        request_path = nil
        allow(command).to receive(:run) do |*args|
          expect(args.take(4)).to eq(['osascript', '-l', 'JavaScript', '-e'])
          script, path = args.last(2)
          property = field == 'comments' ? 'comment' : field
          expect(script).to include("track.#{property} = request.value", "JSON.stringify(track.#{property}())")
          expect(script).not_to include(text, track_id)
          request_path = path
          expect(JSON.parse(File.read(path))).to eq('track_id' => track_id, 'value' => text)
          instance_double(TTY::Command::Result, out: "#{JSON.generate(text)}\n")
        end

        result = nil
        expect { result = library.public_send("update_#{field}", track_id, text) }.to output("updated #{field}\n").to_stdout
        expect(result).to eq(text)
        expect(File.exist?(request_path)).to be(false)
      end

      it 'writes and reads an explicit empty value' do
        allow(command).to receive(:run) do |*, path|
          expect(JSON.parse(File.read(path))['value']).to eq('')
          instance_double(TTY::Command::Result, out: "\"\"\n")
        end

        expect(library.public_send("update_#{field}", track_id, '')).to eq('')
      end

      it 'keeps large text out of the command arguments' do
        large_text = text * 20_000
        allow(command).to receive(:run) do |*args|
          expect(args.join.bytesize).to be < 10_000
          expect(JSON.parse(File.read(args.last))['value']).to eq(large_text)
          instance_double(TTY::Command::Result, out: "#{JSON.generate(large_text)}\n")
        end

        expect(library.public_send("update_#{field}", track_id, large_text)).to eq(large_text)
      end

      it 'cleans up request data and propagates automation failures' do
        request_path = nil
        allow(command).to receive(:run) do |*, path|
          request_path = path
          raise 'automation denied'
        end

        expect { library.public_send("update_#{field}", track_id, text) }.to raise_error('automation denied')
        expect(File.exist?(request_path)).to be(false)
      end

      it 'rejects a changed or missing read-back value and cleans up request data' do
        ['changed text', nil].each do |saved_text|
          request_path = nil
          allow(command).to receive(:run) do |*, path|
            request_path = path
            instance_double(TTY::Command::Result, out: JSON.generate(saved_text))
          end

          expect { library.public_send("update_#{field}", track_id, text) }.to raise_error('music text read-back does not match the queued value')
          expect(File.exist?(request_path)).to be(false)
        end
      end
    end
  end

  describe 'clearing embedded lyrics' do
    let(:repair) { class_double(Update::EmbeddedLyrics) }
    let(:file_info) { { track_id: track_id, path: '/music/track.mp3', lyrics: 'rockdizmusic.com' } }

    before do
      stub_const('Update::EmbeddedLyrics', repair)
      allow(repair).to receive(:clear).and_return('/music/.warehouse-lyrics-backup.bak')
    end

    it 'repairs a failed lyrics clear, refreshes music and verifies the retried clear' do
      requests = []
      allow(command).to receive(:run) do |*args|
        if args.last == track_id
          instance_double(TTY::Command::Result, out: JSON.generate(file_info))
        else
          requests << JSON.parse(File.read(args.last))
          saved = requests.size == 1 ? 'rockdizmusic.com' : ''
          instance_double(TTY::Command::Result, out: JSON.generate(saved))
        end
      end

      expect { expect(library.update_lyrics(track_id, '')).to eq('') }.to output(/updated lyrics/).to_stdout
      expect(repair).to have_received(:clear).with('/music/track.mp3').once
      expect(requests).to eq([{ 'track_id' => track_id, 'value' => '' }, { 'track_id' => track_id, 'value' => '', 'refresh' => true }])
    end

    it 'still fails if music returns nonempty lyrics after the repair' do
      allow(command).to receive(:run) do |*args|
        value = args.last == track_id ? file_info : 'rockdizmusic.com'
        instance_double(TTY::Command::Result, out: JSON.generate(value))
      end

      expect { library.update_lyrics(track_id, '') }.to raise_error('music text read-back does not match the queued value')
      expect(repair).to have_received(:clear).once
    end

    it 'does not repair changed track identities or lyrics' do
      [{ track_id: 'another track' }, { lyrics: 'new edit' }, { path: nil }].each do |change|
        allow(command).to receive(:run) do |*args|
          value = args.last == track_id ? file_info.merge(change) : 'rockdizmusic.com'
          instance_double(TTY::Command::Result, out: JSON.generate(value))
        end

        expect { library.update_lyrics(track_id, '') }.to raise_error(/music track changed/)
      end
      expect(repair).not_to have_received(:clear)
    end

    it 'does not repair comments, nonempty updates or missing read-back values' do
      [['comments', '', 'old comments'], ['lyrics', 'replacement', 'old lyrics'], ['lyrics', '', nil]].each do |field, requested, saved|
        allow(command).to receive(:run).and_return(instance_double(TTY::Command::Result, out: JSON.generate(saved)))

        expect { library.public_send("update_#{field}", track_id, requested) }.to raise_error('music text read-back does not match the queued value')
      end
      expect(repair).not_to have_received(:clear)
    end

    it 'keeps the mismatch failure when the file has no supported embedded lyrics to clear' do
      allow(repair).to receive(:clear).and_return(nil)
      allow(command).to receive(:run) do |*args|
        value = args.last == track_id ? file_info : 'rockdizmusic.com'
        instance_double(TTY::Command::Result, out: JSON.generate(value))
      end

      expect { library.update_lyrics(track_id, '') }.to raise_error('music text read-back does not match the queued value')
      expect(command).to have_received(:run).twice
    end
  end
end
