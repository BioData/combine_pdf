# frozen_string_literal: true

########################################################
## PDF/A Support Module
## This module provides functionality to ensure PDF/A compliance
## according to ISO 19005-1:2005 (PDF/A-1)
########################################################

module CombinePDF
  # @!visibility private
  # This module adds PDF/A compliance features to PDF objects
  module PDFASupport
    # @!visibility private

    protected

    # Generates a file identifier array for the PDF trailer
    # Required by ISO 19005-1:2005 6.1.3
    #
    # The ID array contains two strings:
    # - First string: permanent identifier (based on file content)
    # - Second string: changing identifier (updated on each modification)
    #
    # @param pdf_content [String] The PDF content to generate ID from
    # @return [Array<String>] Two hex-encoded MD5 hash strings
    def generate_file_id(pdf_content = nil)
      # Use current time and some randomness if no content provided
      base_string = pdf_content || "#{Time.now.to_f}#{SecureRandom.hex(16)}"

      # Add document info to make ID more unique
      base_string += @info.to_s if @info

      # Generate permanent identifier (first element)
      permanent_id = Digest::MD5.hexdigest(base_string)

      # Generate changing identifier (second element)
      # This changes on each save/modification
      changing_id = Digest::MD5.hexdigest("#{permanent_id}#{Time.now.to_f}#{SecureRandom.hex(8)}")

      [permanent_id, changing_id]
    end

    # Escape XML special characters
    def escape_xml(text)
      return '' if text.nil?

      text.to_s
          .gsub('&', '&amp;')
          .gsub('<', '&lt;')
          .gsub('>', '&gt;')
          .gsub('"', '&quot;')
          .gsub("'", '&apos;')
    end

    # Generates XMP metadata stream for PDF/A compliance
    # Required by ISO 19005-1:2005 6.7.2 and 6.7.3
    #
    # Creates an XMP packet with metadata from the Info dictionary
    # and PDF/A conformance declaration
    #
    # @return [Hash] A PDF stream object containing XMP metadata
    def generate_xmp_metadata
      # Get current timestamp in XMP format
      timestamp = (if @info[:CreationDate].is_a?(String)
                     parse_pdf_date(@info[:CreationDate])
                   else
                     Time.now
                   end).utc.strftime('%Y-%m-%dT%H:%M:%SZ')

      # Build XMP packet
      xmp_content = <<~XMP
        <?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.6-c015 84.159810, 2016/09/10-02:41:30">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
                xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
                xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
      XMP

      # Add Title (dc:title)
      if @info[:Title] && !@info[:Title].to_s.empty?
        xmp_content += <<~XMP
          <dc:title>
            <rdf:Alt>
              <rdf:li xml:lang="x-default">#{escape_xml(@info[:Title])}</rdf:li>
            </rdf:Alt>
          </dc:title>
        XMP
      end

      # Add Author (dc:creator)
      if @info[:Author] && !@info[:Author].to_s.empty?
        xmp_content += <<~XMP
          <dc:creator>
            <rdf:Seq>
              <rdf:li>#{escape_xml(@info[:Author])}</rdf:li>
            </rdf:Seq>
          </dc:creator>
        XMP
      end

      # Add Subject/Description (dc:description)
      if @info[:Subject] && !@info[:Subject].to_s.empty?
        xmp_content += <<~XMP
          <dc:description>
            <rdf:Alt>
              <rdf:li xml:lang="x-default">#{escape_xml(@info[:Subject])}</rdf:li>
            </rdf:Alt>
          </dc:description>
        XMP
      end

      # Add Keywords (pdf:Keywords)
      if @info[:Keywords] && !@info[:Keywords].to_s.empty?
        xmp_content += <<~XMP
          <pdf:Keywords>#{escape_xml(@info[:Keywords])}</pdf:Keywords>
        XMP
      end

      # Add Producer (pdf:Producer)
      if @info[:Producer] && !@info[:Producer].to_s.empty?
        xmp_content += <<~XMP
          <pdf:Producer>#{escape_xml(@info[:Producer])}</pdf:Producer>
        XMP
      end

      # Add Creator (xmp:CreatorTool)
      creator = @info[:Creator] || @info[:Producer] || 'Unknown'
      xmp_content += <<~XMP
        <xmp:CreatorTool>#{escape_xml(creator)}</xmp:CreatorTool>
      XMP

      # Add timestamps
      xmp_content += <<~XMP
        <xmp:CreateDate>#{timestamp}</xmp:CreateDate>
        <xmp:ModifyDate>#{timestamp}</xmp:ModifyDate>
        <xmp:MetadataDate>#{timestamp}</xmp:MetadataDate>
      XMP

      # Add PDF/A conformance level
      xmp_content += <<~XMP
              <pdfaid:part>1</pdfaid:part>
              <pdfaid:conformance>B</pdfaid:conformance>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
      XMP

      # Create metadata stream object
      {
        Type: :Metadata,
        Subtype: :XML,
        raw_stream_content: xmp_content.force_encoding(Encoding::UTF_8)
      }
    end

    # Generates a minimal sRGB ICC profile stream
    # This creates a basic sRGB v2 ICC profile that's sufficient for PDF/A
    #
    # @return [Hash] ICC profile stream object
    def generate_srgb_icc_profile
      # Minimal sRGB v2 ICC profile structure
      # This is a simplified profile that declares sRGB color space
      # Profile header (128 bytes) + basic tags
      icc_data = [
        # Profile header
        0x00, 0x00, 0x02, 0x30,  # Profile size (560 bytes approximation)
        0x00, 0x00, 0x00, 0x00,  # Preferred CMM type
        0x02, 0x10, 0x00, 0x00,  # Profile version 2.1.0
        0x6D, 0x6E, 0x74, 0x72,  # 'mntr' - Display device profile
        0x52, 0x47, 0x42, 0x20,  # 'RGB ' - RGB color space
        0x58, 0x59, 0x5A, 0x20,  # 'XYZ ' - Connection space
        0x00, 0x00, 0x00, 0x00,  # Date (16 bytes) - we'll use zeros
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x61, 0x63, 0x73, 0x70,  # 'acsp' - signature
        0x00, 0x00, 0x00, 0x00,  # Platform (generic)
        0x00, 0x00, 0x00, 0x00,  # Flags
        0x00, 0x00, 0x00, 0x00,  # Device manufacturer
        0x00, 0x00, 0x00, 0x00,  # Device model
        0x00, 0x00, 0x00, 0x00,  # Device attributes (8 bytes)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,  # Rendering intent
        0x00, 0x00, 0xF6, 0xD6,  # PCS illuminant X (D50)
        0x00, 0x01, 0x00, 0x00,  # PCS illuminant Y
        0x00, 0x00, 0xD3, 0x2D,  # PCS illuminant Z
        0x00, 0x00, 0x00, 0x00,  # Profile creator
        0x00, 0x00, 0x00, 0x00,  # Profile ID (16 bytes)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,  # Reserved (28 bytes)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        # Tag count (9 basic tags)
        0x00, 0x00, 0x00, 0x09,
        # Tag table (tag signature, offset, size) - 12 bytes per tag
        # desc - profile description
        0x64, 0x65, 0x73, 0x63, 0x00, 0x00, 0x00, 0xF0, 0x00, 0x00, 0x00, 0x28,
        # wtpt - white point
        0x77, 0x74, 0x70, 0x74, 0x00, 0x00, 0x01, 0x18, 0x00, 0x00, 0x00, 0x14,
        # rXYZ - red colorant
        0x72, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x00, 0x00, 0x14,
        # gXYZ - green colorant
        0x67, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x00, 0x14,
        # bXYZ - blue colorant
        0x62, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x54, 0x00, 0x00, 0x00, 0x14,
        # rTRC - red tone curve
        0x72, 0x54, 0x52, 0x43, 0x00, 0x00, 0x01, 0x68, 0x00, 0x00, 0x00, 0x0E,
        # gTRC - green tone curve
        0x67, 0x54, 0x52, 0x43, 0x00, 0x00, 0x01, 0x78, 0x00, 0x00, 0x00, 0x0E,
        # bTRC - blue tone curve
        0x62, 0x54, 0x52, 0x43, 0x00, 0x00, 0x01, 0x88, 0x00, 0x00, 0x00, 0x0E,
        # cprt - copyright
        0x63, 0x70, 0x72, 0x74, 0x00, 0x00, 0x01, 0x98, 0x00, 0x00, 0x00, 0x0C,
        # Profile description tag
        0x64, 0x65, 0x73, 0x63,  # 'desc' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x00, 0x00, 0x00, 0x10,  # ASCII string length
        0x73, 0x52, 0x47, 0x42,  # 'sRGB'
        0x20, 0x49, 0x45, 0x43,  # ' IEC'
        0x36, 0x31, 0x39, 0x36,  # '6196'
        0x36, 0x2D, 0x32, 0x2E,  # '6-2.'
        0x31, 0x00, 0x00, 0x00,  # '1' + padding
        # White point (D50)
        0x58, 0x59, 0x5A, 0x20,  # 'XYZ ' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x00, 0x00, 0xF6, 0xD6,  # X
        0x00, 0x01, 0x00, 0x00,  # Y
        0x00, 0x00, 0xD3, 0x2D,  # Z
        # Red colorant
        0x58, 0x59, 0x5A, 0x20,  # 'XYZ ' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x00, 0x00, 0x9C, 0x18,  # X (0.4361)
        0x00, 0x00, 0x4F, 0xA5,  # Y (0.2225)
        0x00, 0x00, 0x04, 0xFC,  # Z (0.0139)
        # Green colorant
        0x58, 0x59, 0x5A, 0x20,  # 'XYZ ' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x00, 0x00, 0x34, 0x76,  # X (0.3851)
        0x00, 0x00, 0xA0, 0x2C,  # Y (0.7169)
        0x00, 0x00, 0x0F, 0x84,  # Z (0.0971)
        # Blue colorant
        0x58, 0x59, 0x5A, 0x20,  # 'XYZ ' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x00, 0x00, 0x1D, 0x42,  # X (0.1431)
        0x00, 0x00, 0x0B, 0x8F,  # Y (0.0606)
        0x00, 0x00, 0xC3, 0xB2,  # Z (0.7141)
        # Red TRC (gamma curve)
        0x63, 0x75, 0x72, 0x76,  # 'curv' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x00, 0x00, 0x00, 0x01,  # count
        0x02, 0x33,              # gamma 2.2 (approximate)
        # Green TRC (same as red)
        0x63, 0x75, 0x72, 0x76,  # 'curv' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x00, 0x00, 0x00, 0x01,  # count
        0x02, 0x33,              # gamma 2.2
        # Blue TRC (same as red)
        0x63, 0x75, 0x72, 0x76,  # 'curv' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x00, 0x00, 0x00, 0x01,  # count
        0x02, 0x33,              # gamma 2.2
        # Copyright
        0x74, 0x65, 0x78, 0x74,  # 'text' type
        0x00, 0x00, 0x00, 0x00,  # reserved
        0x50, 0x44               # 'PD' (Public Domain)
      ].pack('C*').force_encoding(Encoding::ASCII_8BIT)

      # Create ICC profile stream object
      {
        N: 3, # Number of color components (RGB = 3)
        Alternate: :DeviceRGB,
        Filter: :FlateDecode,
        raw_stream_content: Zlib::Deflate.deflate(icc_data)
      }
    end

    # Generates OutputIntent for PDF/A compliance
    # Required by ISO 19005-1:2005 6.2.3
    #
    # Creates an OutputIntent dictionary specifying the color profile
    # for rendering the PDF content
    #
    # @return [Hash] OutputIntent dictionary
    def generate_output_intent
      # Create ICC profile stream
      icc_profile = generate_srgb_icc_profile
      @objects << icc_profile

      # Create OutputIntent dictionary with embedded profile
      {
        Type: :OutputIntent,
        S: :GTS_PDFA1,
        OutputConditionIdentifier: 'sRGB IEC61966-2.1',
        DestOutputProfile: { is_reference_only: true, referenced_object: icc_profile },
        Info: 'sRGB IEC61966-2.1',
        RegistryName: 'http://www.color.org'
      }
    end

    # Parses a PDF date string into a Time object
    # PDF dates are in format: D:YYYYMMDDHHmmSSOHH'mm
    #
    # @param pdf_date [String] PDF date string
    # @return [Time] Parsed time object
    def parse_pdf_date(pdf_date)
      return Time.now unless pdf_date.is_a?(String)

      # Extract date components using regex
      match = pdf_date.match(/D:(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})([+-Z])(\d{2})'?(\d{2})?/)
      return Time.now unless match

      year, month, day, hour, min, sec, tz_sign, tz_hour, tz_min = match.captures
      tz_min ||= '00'

      # Create time object
      time = Time.utc(year.to_i, month.to_i, day.to_i, hour.to_i, min.to_i, sec.to_i)

      # Apply timezone offset
      if tz_sign == '+'
        time -= ((tz_hour.to_i * 3600) + (tz_min.to_i * 60))
      elsif tz_sign == '-'
        time += ((tz_hour.to_i * 3600) + (tz_min.to_i * 60))
      end

      time
    rescue StandardError
      Time.now
    end

    # Adds PDF/A compliance features to the catalog
    # This method is called during PDF generation to inject
    # required metadata and output intents
    #
    # @param catalog [Hash] The catalog dictionary
    # @return [Hash] The modified catalog dictionary
    def add_pdfa_compliance(catalog)
      # Always add XMP metadata stream for PDF/A
      unless catalog[:Metadata]
        metadata_stream = generate_xmp_metadata
        @objects << metadata_stream
        catalog[:Metadata] = { is_reference_only: true, referenced_object: metadata_stream }
      end

      # Only add OutputIntent if:
      # 1. There isn't already one present, AND
      # 2. The PDF uses uncalibrated color spaces (DeviceRGB, DeviceCMYK, DeviceGray)
      if !(catalog[:OutputIntents] || has_output_intent?) && uses_uncalibrated_color_spaces?
        output_intent = generate_output_intent
        @objects << output_intent
        catalog[:OutputIntents] = [{ is_reference_only: true, referenced_object: output_intent }]
      end

      # Fix annotation flags for PDF/A compliance (ISO 19005-1:2005 § 6.5.3)
      fix_annotation_flags

      catalog
    end

    # Fix annotation flags for PDF/A compliance
    # Required by ISO 19005-1:2005 § 6.5.3
    #
    # All annotations must have:
    # - F (Flags) key present
    # - Print flag bit (bit 3, value 4) set to 1
    # - Hidden flag bit (bit 2, value 2) set to 0
    # - Invisible flag bit (bit 1, value 1) set to 0
    # - NoView flag bit (bit 6, value 32) set to 0
    def fix_annotation_flags
      # Scan all pages for annotations
      pages.each do |page|
        # Check for Annots array
        annots = page[:Annots]
        next unless annots

        # Handle reference
        annots = annots[:referenced_object] if annots.is_a?(Hash) && annots[:referenced_object]
        next unless annots.is_a?(Array)

        # Fix each annotation
        annots.each do |annot_ref|
          # Get actual annotation object
          annot = annot_ref
          annot = annot[:referenced_object] if annot.is_a?(Hash) && annot[:referenced_object]
          next unless annot.is_a?(Hash)

          # Only process actual annotation dictionaries
          next unless annot[:Type] == :Annot || annot[:Subtype]

          # Get current flags or default to 0
          flags = annot[:F] || 0

          # PDF/A requirements for annotation flags:
          # Bit 3 (Print, value 4): MUST be 1
          # Bit 2 (Hidden, value 2): MUST be 0
          # Bit 1 (Invisible, value 1): MUST be 0
          # Bit 6 (NoView, value 32): MUST be 0

          flags |= 4    # Set Print flag (bit 3)
          flags &= ~2   # Clear Hidden flag (bit 2)
          flags &= ~1   # Clear Invisible flag (bit 1)
          flags &= ~32  # Clear NoView flag (bit 6)

          # Update the annotation
          annot[:F] = flags
        end
      end
    end

    # Check if the PDF already has an OutputIntent defined
    # @return [Boolean] true if OutputIntent exists
    def has_output_intent?
      @objects.any? { |obj| obj.is_a?(Hash) && obj[:Type] == :OutputIntent }
    end

    # Check if the PDF uses uncalibrated color spaces
    # Uncalibrated spaces are: DeviceRGB, DeviceCMYK, DeviceGray
    # If we find these, we need an OutputIntent for PDF/A compliance
    #
    # @return [Boolean] true if uncalibrated color spaces are used
    def uses_uncalibrated_color_spaces?
      # Check pages for uncalibrated color space usage
      pages.each do |page|
        # Check page resources for color spaces
        resources = page[:Resources]
        resources = resources[:referenced_object] if resources.is_a?(Hash) && resources[:referenced_object]

        next unless resources.is_a?(Hash)

        # Check ColorSpace dictionary
        next unless resources[:ColorSpace]

        cs = resources[:ColorSpace]
        cs = cs[:referenced_object] if cs.is_a?(Hash) && cs[:referenced_object]

        # If we find DeviceRGB, DeviceCMYK, or DeviceGray, we need OutputIntent
        next unless cs.is_a?(Hash)

        cs.each_value do |space|
          space = space[:referenced_object] if space.is_a?(Hash) && space[:referenced_object]

          # Check if it's a device color space (uncalibrated)
          return true if %i[DeviceRGB DeviceCMYK DeviceGray].include?(space)

          # Check array form [/DeviceRGB] or [/CalRGB ...]
          if space.is_a?(Array) && space.length.positive? && %i[DeviceRGB DeviceCMYK DeviceGray].include?(space[0])
            return true
          end
        end
      end

      # If we didn't find any explicit color space definitions,
      # assume DeviceRGB is used (PDF default) and we need OutputIntent
      true
    end
  end
end
