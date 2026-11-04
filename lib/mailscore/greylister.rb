require "digest"

module MailScore
  # Holds back mail from the greylist threshold up, short of reject, until it
  # is retried after the timeout; a retry that passes keeps its own action. A message is seen under two keys: its envelope and client network,
  # and its content, the first BODY_CAP bytes of its body with its Subject,
  # recipients and MIME From. A retry passes when either key is older than the
  # timeout. Local networks and authenticated senders pass without an entry.
  class Greylister
    NAME = "GREYLISTED"
    GROUP = "greylist"
    WEIGHT = 0.0
    DESCRIPTION = "Held for a retry"
    BODY_CAP = 10 * 1024

    # An entry past its expiry that the sweep has not deleted yet counts as gone.
    FIRST_SEEN = "SELECT min(first_seen) FROM greylist WHERE key IN (?, ?) AND expires_at > ?"
    RECORD = "INSERT OR REPLACE INTO greylist (key, first_seen, expires_at) VALUES (?, ?, ?)"
    REFRESH = "UPDATE greylist SET expires_at = ? WHERE key IN (?, ?) AND expires_at > ?"

    def initialize(config, database)
      @config = config
      @database = database
    end

    def greylist(message, envelope, action, now: Time.now)
      if envelope.trusted? || passed?(keys(message, envelope), now.to_i)
        [ action, Hit.new(name: NAME, weight: WEIGHT, detail: "pass") ]
      else
        [ "soft_reject", Hit.new(name: NAME, weight: WEIGHT, detail: "greylisted") ]
      end
    end

    private
      # First sight records every key. A retry passes once either key is past
      # the timeout, which pushes their expiry back; a retry inside the timeout
      # changes nothing, so retrying early never keeps an entry alive.
      def passed?(keys, now)
        expires_at = (now + @config.greylist_expiry).ceil

        @database.transaction do
          first_seen = @database.execute(FIRST_SEEN, *keys, now).dig(0, 0)

          if first_seen.nil?
            keys.each { @database.execute(RECORD, it, now, expires_at) }
            false
          elsif now - first_seen >= @config.greylist_timeout
            @database.execute(REFRESH, expires_at, *keys, now)
            true
          else
            false
          end
        end
      end

      def keys(message, envelope)
        recipients = envelope.recipients.map(&:downcase).uniq.sort
        sender = [ envelope.from.to_s.downcase, *recipients, network(envelope.address) ].join("\0")
        content = [ "body", message.body.byteslice(0, BODY_CAP), message.subject.to_s, *recipients, message.from_addresses.first&.downcase || "<>" ]
        [ "envelope\0#{sender}", content.map(&:b).join("\0".b) ].map { Digest::SHA256.hexdigest(it) }
      end

      def network(address)
        address&.then { it.mask(it.ipv4? ? 19 : 64).to_s }.to_s
      end
  end
end
