# frozen_string_literal: true

require 'etc'
require 'set'

module Opal
  class BuilderScheduler
    class Prefork < BuilderScheduler
      # We hook into the process_requires method
      def process_requires(rel_path, requires, autoloads, options)
        return if requires.empty?

        if @in_fork
          io = @in_fork
          io.send(:new_requires, rel_path, requires, autoloads, options)
        else
          processed = prefork_reactor(rel_path, requires, autoloads, options)

          processed = OrderCorrector.correct_order(processed, requires, builder)

          builder.processed.append(*processed)
        end
      end

      private

      # Prefork is not deterministic. This module corrects an order of processed
      # files so that it would be exactly the same as if building sequentially.
      # While for Ruby files it usually isn't a problem, because the real order
      # stems from how `Opal.modules` array is accessed, the JavaScript files
      # are executed verbatim and their order may be important. Also, having
      # deterministic output is always a good thing.
      module OrderCorrector
        module_function

        def correct_order(processed, requires, builder)
          # Let's build a hash that maps a filename to an array of files it requires
          requires_hash = processed.to_h do |i|
            [i.filename, expand_requires(i.requires, builder)]
          end
          # Let's build an array with a correct order of requires
          order_array = build_require_order_array(expand_requires(requires, builder), requires_hash)
          # If a key is duplicated, remove the last duplicate
          order_array = order_array.uniq
          # Create a hash from this array: [a,b,c] => [a => 0, b => 1, c => 2]
          order_hash = order_array.each_with_index.to_h
          # Let's return a processed array that has elements in the order provided
          processed.sort_by do |asset|
            # If a filename isn't present somehow in our hash, let's put it at the end
            order_hash[asset.filename] || order_array.length
          end
        end

        # Expand a requires array, so that the requires filenames will be
        # matching BuilderProcessor#. Builder needs to be passed so that
        # we can access an `expand_ext` function from its context.
        def expand_requires(requires, builder)
          requires.map { |i| builder.expand_ext(i) }
        end

        def build_require_order_array(requires, requires_hash, built_for = Set.new)
          array = []
          requires.each do |name|
            next if built_for.include?(name)
            built_for << name

            asset_requires = requires_hash[name]
            array += build_require_order_array(asset_requires, requires_hash, built_for) if asset_requires
            array << name
          end
          array
        end
      end

      class ForkSet < Array
        def initialize(count, &block)
          super([])

          @count, @block = count, block

          create_fork
        end

        def get_events(queue_length)
          # Wait for anything to happen:
          # - Either any of our workers return some data
          # - Or any workers become ready to receive data
          #   - But only if we have enough work for them
          ios = IO.select(
            map(&:read_io),
            sample(queue_length).map(&:write_io),
            []
          )
          return [[], []] unless ios

          events = ios[0].map do |io|
            io = from_io(io, :read_io)
            [io, *io.recv]
          end

          idles = ios[1].map do |io|
            from_io(io, :write_io)
          end

          # Progressively create forks, because we may not need all
          # the workers at the time. The number 6 was picked due to
          # some trial and error on a Ryzen machine.
          #
          # Do note that prefork may happen more than once.
          create_fork if length < @count && rand(6) == 1

          [events, idles]
        end

        def create_fork
          self << Fork.new(self, &@block)
        end

        def from_io(io, type)
          find { |i| i.__send__(type) == io }
        end

        def close
          each(&:close)
        end

        def wait
          each(&:wait)
        end
      end

      class Fork
        def initialize(forkset)
          @parent_read, @child_write = IO.pipe(binmode: true)
          @child_read, @parent_write = IO.pipe(binmode: true)
          @forkset = forkset
          @in_fork = false

          @pid = fork do
            @in_fork = true

            begin
              @parent_read.close
              @parent_write.close

              yield(self)
            rescue => error
              send(:exception, error)
            ensure
              send(:close) unless write_io.closed?
              @child_write.close
            end
          end

          @child_read.close
          @child_write.close
        end

        def close
          send(:close)
          @parent_write.close
        end

        def goodbye
          read_io.close unless read_io.closed?
        end

        def send_message(io, msg)
          msg = Marshal.dump(msg)
          io.write([msg.length].pack('Q') + msg)
        end

        def recv_message(io)
          length, = *io.read(8).unpack('Q')
          Marshal.load(io.read(length)) # rubocop:disable Security/MarshalLoad
        end

        def fork?
          @in_fork
        end

        def read_io
          fork? ? @child_read : @parent_read
        end

        def write_io
          fork? ? @child_write : @parent_write
        end

        def eof?
          write_io.closed?
        end

        def send(*msg)
          send_message(write_io, msg)
        end

        def recv
          recv_message(read_io)
        end

        def wait
          Process.waitpid(@pid, Process::WNOHANG)
        end
      end

      # By default we use 3/4 of CPU threads detected.
      # rubocop:disable Lint/RedundantSafeNavigation
      def fork_count
        ENV['OPAL_PREFORK_THREADS']&.to_i || (Etc.nprocessors * 3 / 4.0).ceil
      end
      # rubocop:enable Lint/RedundantSafeNavigation

      def prefork
        @forks = ForkSet.new(fork_count, &method(:fork_entrypoint))
      end

      def fork_entrypoint(io)
        # Ensure we can work with our forks async...
        Fiber.set_scheduler(nil) if Fiber.respond_to? :set_scheduler

        @in_fork = io

        until io.eof?
          $0 = 'opal/builder: idle'

          type, *args = *io.recv
          case type
          when :compile
            rel_path, req, autoloads, options = *args
            $0 = "opal/builder: #{req}"
            begin
              asset = builder.process_require_threadsafely(req, autoloads, options)
              io.send(:new_asset, asset)
            rescue Builder::MissingRequire => error
              io.send(:missing_require_exception, rel_path, error)
            end
          when :close
            io.goodbye
            break
          end
        end
      rescue Errno::EPIPE
        exit!
      end

      def prefork_reactor(rel_path, requires, autoloads, options)
        prefork

        processed = []

        first = rel_path
        queue = requires.map { |i| [rel_path, i, autoloads, options] }

        awaiting = 0
        built = 0
        should_log = $stderr.tty? && !ENV['OPAL_DISABLE_PREFORK_LOGS']

        $stderr.print "\r\e[K" if should_log

        loop do
          events, idles = @forks.get_events(queue.length)

          idles.each do |io|
            break if queue.empty?

            rel_path, req, autoloads, options = *queue.shift

            next if builder.already_processed.include?(req)
            awaiting += 1
            builder.already_processed << req
            io.send(:compile, rel_path, req, autoloads, options)
          end

          events.each do |io, type, *args|
            case type
            when :new_requires
              rel_path, requires, autoloads, options = *args
              requires.each do |i|
                queue << [rel_path, i, autoloads, options]
              end
            when :new_asset
              asset, = *args
              if !asset
                # Do nothing, we received a nil which is expected.
              else
                processed << asset
              end
              built += 1
              awaiting -= 1
            when :missing_require_exception
              rel_path, error = *args
              raise error, "A file required by #{rel_path.inspect} wasn't found.\n#{error.message}", error.backtrace
            when :exception
              error, = *args
              raise error
            when :close
              io.goodbye
            end
          end

          if should_log
            percent = (100.0 * built / (awaiting + built)).round(1)
            str = format("[opal/builder] Building %<first>s... (%<percent>4.3g%%)\r", first: first, percent: percent)
            $stderr.print str
          end

          break if awaiting == 0 && queue.empty?
        end

        processed
      ensure
        $stderr.print "\r\e[K\r" if should_log
        @forks.close
        @forks.wait
      end
    end
  end
end
