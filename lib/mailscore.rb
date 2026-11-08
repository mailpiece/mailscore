require "logger"
require "mailscore/version"
require "mailscore/config"
require "mailscore/database"
require "mailscore/message"
require "mailscore/content"
require "mailscore/limits"
require "mailscore/envelope"
require "mailscore/reverse_dns"
require "mailscore/nameservers"
require "mailscore/bayes"
require "mailscore/classifier"
require "mailscore/rules"
require "mailscore/stats"
require "mailscore/greylister"
require "mailscore/origin"
require "mailscore/reputation"
require "mailscore/fuzzy"
require "mailscore/trap"
require "mailscore/spam_headers"
require "mailscore/scanner"
require "mailscore/app"

# Mail scoring daemon.
module MailScore
  LOG_FIELD_CAP = 64

  class << self
    attr_writer :logger, :nameservers, :offline_dns_lists

    # One line per scan, learn and fuzzy change, and the errors, to stdout.
    # Never message content, Subjects or addresses. See docs/deploy.md.
    def logger
      @logger ||= Logger.new($stdout, progname: "mailscore")
    end

    # A value from a request as one log field: printable ASCII without
    # spaces, at most LOG_FIELD_CAP characters, or - when none is left, so a
    # caller can't forge a line or a field.
    def log_field(value)
      value.to_s.b.delete("^\x21-\x7e")[0, LOG_FIELD_CAP].then { it.empty? ? "-" : it }
    end

    # The nameservers DNS goes to, set at boot from the config. See Nameservers.
    def nameservers
      @nameservers ||= Nameservers.new(nil)
    end

    # The zones of the DNS lists offline, as this worker last read them. See
    # DnsList::Monitor.
    def offline_dns_lists
      @offline_dns_lists ||= Set.new
    end
  end
end
