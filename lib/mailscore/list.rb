module MailScore
  # A list file read as a set: a word a line, lowercased, past comments and
  # blank lines. It is read again once its stat changes, checked on use at
  # most every CHECK_EVERY seconds by each worker on its own. A file that
  # goes missing or can't be read keeps the last list, and one just emptied
  # is read a check later, past an editor's rewrite.
  class List
    CHECK_EVERY = 30
    CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    # The stat fields compared for a change, all but atime.
    STAT = %i[ dev ino mode nlink uid gid rdev size mtime ctime ].freeze

    # Raises SystemCallError or ArgumentError for a file it can't read.
    def initialize(path, clock: CLOCK)
      @path, @clock = path, clock
      @checked = clock.()
      @stat = @last_stat = stat
      @words = read
    end

    def include?(word)
      words.include?(word)
    end

    private
      def words
        reload if @clock.() - @checked >= CHECK_EVERY
        @words
      end

      # The stat first, so a write during the read is read on the next check.
      def reload
        @checked = @clock.()
        previous = @last_stat
        @last_stat = stat

        if @last_stat != @stat
          if truncated_since?(previous)
            MailScore.logger.info "list truncated, read on the next check: #{@path}"
          else
            @words = read
            @stat = @last_stat
            MailScore.logger.info "list reloaded: #{@path}"
          end
        end
      rescue SystemCallError, ArgumentError => error
        MailScore.logger.warn "list reload failed, kept the last: #{@path}: #{error.message}"
      end

      # A file just cut to nothing may be an editor still writing it.
      def truncated_since?(previous)
        @last_stat[:size].zero? && previous[:size].positive?
      end

      def stat
        File.stat(@path).then { |stat| STAT.to_h { [ it, stat.public_send(it) ] } }
      end

      def read
        File.readlines(@path, chomp: true).filter_map { it.sub(/#.*/, "").split.first&.downcase }.to_set.freeze
      end
  end
end
