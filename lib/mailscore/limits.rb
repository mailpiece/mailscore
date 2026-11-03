module MailScore
  # How far a message is read. Past a cap the rest is skipped, and the cap
  # fires its symbol once the scan ends, whatever else ran. A cap no ordinary
  # mail reaches weighs a little; one a long newsletter may reach weighs
  # nothing.
  module Limits
    NAME = "LIMITS"

    SYMBOLS = {
      "TOO_MANY_HEADERS" => [ 1.0, "More header fields than are read" ],
      "TOO_MANY_PARTS" => [ 1.0, "More MIME parts than are read" ],
      "TOO_MANY_ZIP_ENTRIES" => [ 0.0, "More zip entry names than are read" ],
      "TOO_MANY_LINKS" => [ 0.0, "More links than are read, or more link domains than a DNS list is asked" ]
    }.freeze

    def self.hits(message)
      message.limits.map { Hit.new(name: it, weight: SYMBOLS.fetch(it).first) }
    end
  end
end
