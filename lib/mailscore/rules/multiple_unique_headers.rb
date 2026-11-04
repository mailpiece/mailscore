module MailScore
  module Rules
    # A field a message carries at most once, repeated, so that one reader
    # may take the first and another the last. Weighs by the share of the
    # worst field repeated.
    class MultipleUniqueHeaders < Rule
      NAME = "UNIQUE_HEADER_REPEATED"
      GROUP = "headers"
      WEIGHT = 7.0
      DESCRIPTION = "Repeated header that must appear once"

      FIELDS = {
        "Content-Type" => 1.0, "Content-Transfer-Encoding" => 1.0, "Date" => 0.1, "From" => 1.0, "Sender" => 1.0,
        "Reply-To" => 1.0, "To" => 0.2, "Cc" => 0.1, "Bcc" => 0.1, "Message-ID" => 0.7, "In-Reply-To" => 0.7,
        "References" => 0.3, "Subject" => 0.7
      }.freeze

      def run(message, _envelope)
        repeated = FIELDS.select { |field, _| message.header_values(field).size > 1 }
        Hit.new(name: NAME, weight: (WEIGHT * repeated.values.max).round(2), detail: repeated.keys.join(", ")) if repeated.any?
      end
    end
  end
end
