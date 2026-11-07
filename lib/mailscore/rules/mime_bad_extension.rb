module MailScore
  module Rules
    # An attachment, or a file named inside a zip, that runs code when opened.
    class MimeBadExtension < Rule
      NAME = "ATTACHMENT_RISKY_EXTENSION"
      GROUP = "mime_types"
      WEIGHT = 2.0
      DESCRIPTION = "Risky attachment type"

      def run(message, _envelope)
        message.content.attachments.each do |attachment|
          name = [ attachment.name, *attachment.archive_names ].find { @config.risky_extensions.include?(Content.extension(it)) }
          return Hit.new(name: NAME, weight: WEIGHT, detail: name) if name
        end

        nil
      end
    end
  end
end
