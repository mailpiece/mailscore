module MailScore
  module Rules
    # A program, found by its first bytes, attached under a name whose
    # extension is not a risky one, such as a Windows executable named
    # invoice.pdf or a Java program named photos.zip.
    class MimeDisguisedProgram < Rule
      NAME = "ATTACHMENT_DISGUISED_PROGRAM"
      GROUP = "programs"
      WEIGHT = 12.0
      DESCRIPTION = "Program attached under a harmless name"

      # A program's kind by its first bytes. CAFEBABE is a universal Mach-O
      # binary or a Java class, both programs.
      MAGIC = {
        "elf" => [ "\x7FELF" ],
        "macho" => [ "\xFE\xED\xFA\xCE", "\xFE\xED\xFA\xCF", "\xCE\xFA\xED\xFE", "\xCF\xFA\xED\xFE", "\xCA\xFE\xBA\xBE" ],
        "lnk" => [ "L\0\0\0\x01\x14\x02\0" ],
        "vhd" => [ "conectix", "vhdxfile" ],
        "script" => [ "#!" ]
      }.transform_values { |magics| magics.map(&:b) }.freeze
      ZIP = [ "PK\x03\x04".b, "PK\x05\x06".b ].freeze
      HEAD = 1024

      def run(message, _envelope)
        attachment, kind = disguised(message.content.attachments)

        if attachment
          Hit.new(name: NAME, weight: WEIGHT, detail: "#{attachment.name} is #{kind}")
        end
      end

      private
        # The first attachment that is a program under a harmless name, and
        # its kind.
        def disguised(attachments)
          attachments.lazy.select { disguise?(it.extension) }.map { [ it, kind(it) ] }.find { |_, kind| kind }
        end

        # A name with an extension, and not a risky one.
        def disguise?(extension)
          !extension.empty? && !@config.risky_extensions.include?(extension)
        end

        def kind(attachment)
          head = Content.decode(attachment.part, HEAD).b

          if head.bytesize < 4
            nil
          elsif windows?(attachment, head)
            "exe"
          elsif head.start_with?(*ZIP)
            zipped_program(attachment)
          else
            MAGIC.find { |_, magics| head.start_with?(*magics) }&.first
          end
        end

        # MZ, then the PE signature where its DOS header says, which may lie
        # past the head.
        def windows?(attachment, head)
          if head.start_with?("MZ") && head.bytesize >= 0x40
            offset = head.byteslice(0x3C, 4).unpack1("V")
            bytes = offset + 4 > head.bytesize ? Content.decode(attachment.part, offset + 4).b : head
            bytes.byteslice(offset, 4) == "PE\0\0".b
          end
        end

        # A zip holding an Android app, or a Java program with its manifest.
        def zipped_program(attachment)
          names = Content.zip_entries(Content.decode(attachment.part, Content::ARCHIVE_CAP))

          if names.include?("AndroidManifest.xml") || names.include?("classes.dex")
            "apk"
          elsif names.include?("META-INF/MANIFEST.MF") && names.any? { it.end_with?(".class") }
            "jar"
          end
        end
    end
  end
end
