module MailScore
  module Rules
    # An attachment, or a file named inside a zip, that runs code when opened.
    # An attachment whose first bytes show a program of a kind on the risky
    # list, such as a Windows executable named invoice.pdf, fires too, but at
    # weight 0 for now: the symbol's weight stays with names until real mail
    # shows the content check does not misfire.
    class MimeBadExtension < Rule
      NAME = "ATTACHMENT_RISKY_EXTENSION"
      GROUP = "mime_types"
      WEIGHT = 2.0
      DESCRIPTION = "Risky attachment type"

      # A program's kind, as an extension, by its first bytes. CAFEBABE is a
      # Java class or a universal Mach-O binary alike.
      MAGIC = {
        "elf" => [ "\x7FELF" ],
        "macho" => [ "\xFE\xED\xFA\xCE", "\xFE\xED\xFA\xCF", "\xCE\xFA\xED\xFE", "\xCF\xFA\xED\xFE" ],
        "class" => [ "\xCA\xFE\xBA\xBE" ],
        "lnk" => [ "L\0\0\0\x01\x14\x02\0\0\0\0\0\xC0\0\0\0\0\0\0F" ]
      }.transform_values { |magics| magics.map(&:b) }.freeze
      # How far into a file its Windows PE header is looked for.
      HEAD = 1024

      def run(message, _envelope)
        attachments = message.content.attachments
        by_name(attachments) || by_content(attachments)
      end

      private
        def by_name(attachments)
          attachments.each do |attachment|
            name = [ attachment.name, *attachment.archive_names ].find { @config.risky_extensions.include?(Content.extension(it)) }
            return Hit.new(name: NAME, weight: WEIGHT, detail: name) if name
          end

          nil
        end

        def by_content(attachments)
          attachments.each do |attachment|
            kind = kind(Content.decode(attachment.part, HEAD).b)
            return Hit.new(name: NAME, weight: 0.0, detail: "#{attachment.name || attachment.type} is #{kind}") if @config.risky_extensions.include?(kind)
          end

          nil
        end

        def kind(head)
          if windows?(head) then "exe"
          else MAGIC.find { |_, magics| magics.any? { head.start_with?(it) } }&.first
          end
        end

        # MZ, then at the offset the DOS header gives, the PE signature.
        def windows?(head)
          head.start_with?("MZ") && head.bytesize >= 0x40 && head.byteslice(head.byteslice(0x3C, 4).unpack1("V"), 4) == "PE\0\0".b
        end
    end
  end
end
