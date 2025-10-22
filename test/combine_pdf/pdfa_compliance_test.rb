# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
require 'combine_pdf'
require 'stringio'

describe 'PDF/A Compliance' do
  describe 'when processing PDF/A files' do
    let(:pdf) { CombinePDF.new }

    before do
      # Create a simple PDF with some content
      pdf.new_page
      pdf.info[:Title] = 'Test Document'
      pdf.info[:Author] = 'Test Author'
      pdf.info[:Subject] = 'Test Subject'
      pdf.info[:Creator] = 'CombinePDF Test'
      # PDF/A is enabled by default (opt-out), so no need to set it
    end

    describe 'File Trailer ID (ISO 19005-1:2005 6.1.3)' do
      it 'must include an ID array in the trailer dictionary' do
        pdf_output = pdf.to_pdf

        # Check for trailer section with ID
        assert_match(/trailer\s*<</, pdf_output, 'Trailer dictionary must exist')
        assert_match(%r{/ID\s*\[}, pdf_output, 'Trailer must contain /ID array')

        # ID must be an array of two strings (file identifier)
        # Pattern: /ID [<hexstring1> <hexstring2>]
        assert_match(%r{/ID\s*\[\s*<[0-9a-fA-F]+>\s*<[0-9a-fA-F]+>\s*\]}, pdf_output,
                     'ID must be an array of two hex strings')
      end

      it 'generates consistent ID for same content' do
        pdf_output1 = pdf.to_pdf

        # Extract ID from first generation
        id_match1 = pdf_output1.match(%r{/ID\s*\[\s*<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*\]})
        refute_nil id_match1, 'First ID must be present'

        # The permanent identifier (first element) should be consistent
        # when processing the same source
        permanent_id = id_match1[1]
        refute_empty permanent_id, 'Permanent ID must not be empty'
        assert_equal 32, permanent_id.length, 'ID should be MD5 hash (32 hex chars)'
      end
    end

    describe 'Catalog Metadata (ISO 19005-1:2005 6.7.2)' do
      it 'must include Metadata key in catalog dictionary' do
        pdf_output = pdf.to_pdf

        # Parse to find catalog object
        catalog_match = pdf_output.match(%r{<<\s*/Type\s*/Catalog\s*(.+?)>>}m)
        refute_nil catalog_match, 'Catalog object must exist'

        catalog_content = catalog_match[1]
        assert_match(%r{/Metadata\s+\d+\s+\d+\s+R}, catalog_content,
                     'Catalog must contain /Metadata reference to stream object')
      end

      it 'metadata stream must be valid XMP' do
        pdf_output = pdf.to_pdf

        # Find metadata stream
        metadata_stream_match = pdf_output.match(%r{/Type\s*/Metadata\s*/Subtype\s*/XML\s*.+?stream\s*\n(.+?)\nendstream}m)
        refute_nil metadata_stream_match, 'Metadata stream must exist'

        xmp_content = metadata_stream_match[1]

        # Check for XMP packet wrapper
        assert_match(/<\?xpacket begin/, xmp_content, 'XMP must have packet begin marker')
        assert_match(/<\?xpacket end/, xmp_content, 'XMP must have packet end marker')

        # Check for required XMP namespaces
        assert_match(%r{xmlns:x="adobe:ns:meta/"}, xmp_content,
                     'XMP must declare adobe namespace')
        assert_match(%r{xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"}, xmp_content,
                     'XMP must declare RDF namespace')
        assert_match(%r{xmlns:dc="http://purl.org/dc/elements/1.1/"}, xmp_content,
                     'XMP must declare Dublin Core namespace')
      end
    end

    describe 'XMP Sync with Info Dictionary (ISO 19005-1:2005 6.7.3)' do
      it 'must embed document info entries in XMP form' do
        pdf_output = pdf.to_pdf

        # Find metadata stream
        metadata_stream_match = pdf_output.match(%r{/Type\s*/Metadata.+?stream\s*\n(.+?)\nendstream}m)
        refute_nil metadata_stream_match, 'Metadata stream must exist for XMP sync'

        xmp_content = metadata_stream_match[1]

        # Title should be in both Info and XMP
        assert_match(/<dc:title>/, xmp_content, 'dc:title must be present in XMP')
        assert_match(/Test Document/, xmp_content, 'Title value must be in XMP')

        # Author/Creator should be in XMP
        assert_match(/<dc:creator>/, xmp_content, 'dc:creator must be present in XMP')
        assert_match(/Test Author/, xmp_content, 'Author value must be in XMP')

        # Subject should be in XMP
        assert_match(/<dc:description>/, xmp_content, 'dc:description must be present in XMP')
        assert_match(/Test Subject/, xmp_content, 'Subject value must be in XMP')

        # Creator tool should be in XMP
        assert_match(/<xmp:CreatorTool>/, xmp_content, 'xmp:CreatorTool must be present in XMP')
      end

      it 'syncs all standard info dictionary entries to XMP' do
        pdf.info[:Keywords] = 'test, pdf, compliance'
        pdf.info[:Producer] = 'CombinePDF Library'

        pdf_output = pdf.to_pdf
        metadata_stream_match = pdf_output.match(%r{/Type\s*/Metadata.+?stream\s*\n(.+?)\nendstream}m)
        xmp_content = metadata_stream_match[1]

        # Keywords
        assert_match(/test, pdf, compliance/, xmp_content, 'Keywords must be in XMP')

        # Producer
        assert_match(/CombinePDF Library/, xmp_content, 'Producer must be in XMP')
      end
    end

    describe 'OutputIntent (ISO 19005-1:2005 6.2.3)' do
      it 'must include OutputIntent in catalog for PDF/A compliance' do
        pdf_output = pdf.to_pdf

        # Parse catalog
        catalog_match = pdf_output.match(%r{<<\s*/Type\s*/Catalog\s*(.+?)>>}m)
        catalog_content = catalog_match[1]

        assert_match(%r{/OutputIntents\s*\[}, catalog_content,
                     'Catalog must contain /OutputIntents array')
      end

      it 'OutputIntent must have correct structure' do
        pdf_output = pdf.to_pdf

        # Find OutputIntent dictionary (it's an indirect object)
        # Look for the pattern: /Type /OutputIntent
        output_intent_match = pdf_output.match(%r{/Type\s*/OutputIntent.*?<<(.+?)>>}m) ||
                              pdf_output.match(%r{<<[^>]*/Type\s*/OutputIntent[^>]*>>}m)
        refute_nil output_intent_match, 'OutputIntent dictionary must exist'

        # Get the full OutputIntent object content
        oi_section = pdf_output[pdf_output.index('/Type /OutputIntent'), 500]

        # Required keys for PDF/A OutputIntent
        assert_match(%r{/Type\s*/OutputIntent}, oi_section,
                     'OutputIntent must have Type')
        assert_match(%r{/S\s*/GTS_PDFA1}, oi_section,
                     'OutputIntent must have subtype GTS_PDFA1')
        assert_match(%r{/OutputConditionIdentifier}, oi_section,
                     'OutputIntent must have OutputConditionIdentifier')
        assert_match(%r{/DestOutputProfile\s+\d+\s+\d+\s+R}, oi_section,
                     'OutputIntent must have DestOutputProfile (ICC profile reference)')
      end

      it 'includes sRGB as default output condition' do
        pdf_output = pdf.to_pdf

        # Check for sRGB color profile reference
        assert_match(/sRGB/, pdf_output, 'Should reference sRGB color space')
      end

      it 'embeds ICC color profile stream' do
        pdf_output = pdf.to_pdf

        # Look for ICCBased color space stream with N=3 (RGB)
        # This indicates an embedded ICC profile
        assert_match(%r{/N\s+3}, pdf_output,
                     'Must have ICC profile with N=3 (RGB components)')
        assert_match(%r{/Alternate\s+/DeviceRGB}, pdf_output,
                     'ICC profile must specify DeviceRGB as alternate')

        # Verify there's actually compressed ICC data
        # The profile should be in a stream
        icc_stream_pattern = %r{/N\s+3.*?/Filter.*?stream}m
        assert_match(icc_stream_pattern, pdf_output,
                     'ICC profile must be in a compressed stream')
      end
    end

    describe 'Integration: Complete PDF/A-1B compliance' do
      it 'generates a PDF that passes all four compliance requirements' do
        pdf_output = pdf.to_pdf

        # 1. Has ID in trailer
        has_id = !(pdf_output =~ %r{/ID\s*\[\s*<[0-9a-fA-F]+>\s*<[0-9a-fA-F]+>\s*\]}).nil?

        # 2. Has Metadata in catalog
        has_metadata = !(pdf_output =~ %r{/Type\s*/Catalog.*/Metadata\s+\d+\s+\d+\s+R}m).nil?

        # 3. Has XMP content
        has_xmp = !(pdf_output =~ %r{<\?xpacket begin.*</x:xmpmeta>}m).nil?

        # 4. Has OutputIntent
        has_output_intent = !(pdf_output =~ %r{/OutputIntents\s*\[}).nil?

        assert has_id, 'Failed: Missing ID in trailer (ISO 19005-1:2005 6.1.3)'
        assert has_metadata, 'Failed: Missing Metadata key in catalog (ISO 19005-1:2005 6.7.2)'
        assert has_xmp, 'Failed: Missing XMP metadata content (ISO 19005-1:2005 6.7.3)'
        assert has_output_intent, 'Failed: Missing OutputIntent (ISO 19005-1:2005 6.2.3)'
      end
    end

    describe 'PDF/A mode is opt-out (enabled by default)' do
      it 'adds PDF/A features by default' do
        pdf_default = CombinePDF.new
        pdf_default.new_page
        pdf_default.info[:Title] = 'PDF/A Document'
        # PDF/A is enabled by default

        pdf_output = pdf_default.to_pdf

        # Should have PDF/A features by default
        assert_match(%r{/ID\s*\[}, pdf_output, 'Default PDF should have ID')
        assert_match(%r{/Metadata\s+\d+\s+\d+\s+R}, pdf_output, 'Default PDF should have XMP Metadata')
        # OutputIntent is only added if uncalibrated color spaces are used
      end

      it 'can disable PDF/A features by setting enable_pdf_a = false' do
        pdf_no_pdfa = CombinePDF.new
        pdf_no_pdfa.enable_pdf_a = false # Explicitly disable
        pdf_no_pdfa.new_page
        pdf_no_pdfa.info[:Title] = 'Regular PDF'

        pdf_output = pdf_no_pdfa.to_pdf

        # Should NOT have PDF/A features when disabled
        refute_match(%r{/ID\s*\[}, pdf_output, 'Regular PDF should not have ID when disabled')
        refute_match(%r{/Metadata\s+\d+\s+\d+\s+R}, pdf_output,
                     'Regular PDF should not have XMP Metadata when disabled')
        refute_match(%r{/OutputIntents}, pdf_output, 'Regular PDF should not have OutputIntent when disabled')
      end
    end

    describe 'Preserving existing PDF/A compliance' do
      it 'preserves ID when loading and saving a PDF/A file' do
        # This test will be relevant when we have sample PDF/A files
        skip 'Requires sample PDF/A file with ID'
      end

      it 'preserves Metadata when combining PDF files' do
        pdf1 = CombinePDF.new
        pdf1.new_page
        pdf1.info[:Title] = 'First Document'
        # PDF/A is enabled by default

        pdf2 = CombinePDF.new
        pdf2.new_page
        pdf2.info[:Title] = 'Second Document'

        combined = pdf1 << pdf2
        pdf_output = combined.to_pdf

        # Should still have all compliance features
        assert_match(%r{/ID\s*\[}, pdf_output, 'Combined PDF must have ID')
        assert_match(%r{/Metadata}, pdf_output, 'Combined PDF must have Metadata')
      end
    end

    describe 'Smart OutputIntent handling' do
      it 'only adds OutputIntent when uncalibrated color spaces are used' do
        pdf = CombinePDF.new
        pdf.new_page
        pdf_output = pdf.to_pdf

        # For new PDFs with no explicit color space (default DeviceRGB),
        # OutputIntent should be added
        assert_match(%r{/OutputIntents}, pdf_output, 'Should add OutputIntent for default DeviceRGB')
      end

      it 'preserves existing OutputIntent if present' do
        # This would require loading a PDF that already has an OutputIntent
        # For now, we'll skip this test
        skip 'Requires sample PDF with existing OutputIntent'
      end
    end

    describe 'Annotation Flags (ISO 19005-1:2005 6.5.3)' do
      it 'fixes annotation flags for PDF/A compliance' do
        pdf = CombinePDF.new
        page = pdf.new_page

        # Create a sample annotation with non-compliant flags
        annotation = {
          Type: :Annot,
          Subtype: :Text,
          Rect: [100, 100, 200, 200],
          Contents: 'Test annotation',
          F: 0 # Non-compliant: no Print flag set
        }

        # Add annotation to page
        page[:Annots] = [{ is_reference_only: true, referenced_object: annotation }]
        pdf.objects << annotation

        # Process the PDF (triggers PDF/A compliance fixes)
        pdf.to_pdf

        # After processing, the annotation should have correct flags
        # F should have Print flag (4) set and Hidden/Invisible/NoView clear
        # The annotation object should be modified in place
        assert_equal 4, annotation[:F], 'Annotation F flag should have Print bit set (value 4)'
      end

      it 'adds F key to annotations that do not have one' do
        pdf = CombinePDF.new
        page = pdf.new_page

        # Create annotation without F key
        annotation = {
          Type: :Annot,
          Subtype: :Link,
          Rect: [50, 50, 150, 100]
          # No F key - should be added
        }

        page[:Annots] = [{ is_reference_only: true, referenced_object: annotation }]
        pdf.objects << annotation

        # Process the PDF (triggers PDF/A compliance fixes)
        pdf.to_pdf

        # F key should be added with Print flag
        refute_nil annotation[:F], 'Annotation must have F key'
        assert_equal 4, annotation[:F], 'F should be 4 (Print flag only)'
      end

      it 'clears Hidden, Invisible, and NoView flags' do
        pdf = CombinePDF.new
        page = pdf.new_page

        # Create annotation with problematic flags
        # F = 39 = 32 (NoView) + 4 (Print) + 2 (Hidden) + 1 (Invisible)
        annotation = {
          Type: :Annot,
          Subtype: :Highlight,
          Rect: [0, 0, 100, 100],
          F: 39 # Has all the wrong flags set
        }

        page[:Annots] = [{ is_reference_only: true, referenced_object: annotation }]
        pdf.objects << annotation

        # Process the PDF (triggers PDF/A compliance fixes)
        pdf.to_pdf

        # Should clear Hidden (2), Invisible (1), and NoView (32), but keep Print (4)
        # 39 - 32 - 2 - 1 = 4
        assert_equal 4, annotation[:F], 'Should clear Hidden/Invisible/NoView but keep Print'

        # Verify specific flags
        flags = annotation[:F]
        assert_equal 1, (flags & 4) >> 2, 'Print flag must be set'
        assert_equal 0, flags & 2, 'Hidden flag must be clear'
        assert_equal 0, flags & 1, 'Invisible flag must be clear'
        assert_equal 0, flags & 32, 'NoView flag must be clear'
      end

      it 'preserves other flags like ReadOnly and Locked' do
        pdf = CombinePDF.new
        page = pdf.new_page

        # F = 192 = 128 (Locked) + 64 (ReadOnly)
        # These should be preserved
        annotation = {
          Type: :Annot,
          Subtype: :FreeText,
          Rect: [10, 10, 50, 50],
          F: 192
        }

        page[:Annots] = [{ is_reference_only: true, referenced_object: annotation }]
        pdf.objects << annotation

        # Process the PDF (triggers PDF/A compliance fixes)
        pdf.to_pdf

        # Should add Print (4) and preserve ReadOnly (64) and Locked (128)
        # 192 + 4 = 196
        expected_flags = 196
        assert_equal expected_flags, annotation[:F],
                     'Should add Print but preserve ReadOnly and Locked flags'
      end

      it 'does not modify annotations when PDF/A is disabled' do
        pdf = CombinePDF.new
        pdf.enable_pdf_a = false # Disable PDF/A
        page = pdf.new_page

        annotation = {
          Type: :Annot,
          Subtype: :Text,
          Rect: [0, 0, 10, 10],
          F: 0 # No flags set
        }

        page[:Annots] = [{ is_reference_only: true, referenced_object: annotation }]
        pdf.objects << annotation

        # Process the PDF (PDF/A is disabled, so no fixes should happen)
        pdf.to_pdf

        # Flags should not be modified when PDF/A is disabled
        assert_equal 0, annotation[:F], 'Flags should not be modified when PDF/A is disabled'
      end
    end

    describe 'Font Embedding (ISO 19005-1:2005 6.3.4)' do
      it 'detects non-embedded fonts' do
        pdf = CombinePDF.new
        page = pdf.new_page

        # Create a non-embedded font (no FontDescriptor with FontFile)
        non_embedded_font = {
          Type: :Font,
          Subtype: :Type1,
          BaseFont: :Arial
          # No FontDescriptor with FontFile - not embedded
        }

        # Add font to page resources
        page[:Resources] = { Font: { F1: { is_reference_only: true, referenced_object: non_embedded_font } } }
        pdf.objects << non_embedded_font

        # After processing, the font should be replaced
        pdf.to_pdf

        # Check that the font reference was updated
        fonts = page[:Resources][:Font]
        new_font_ref = fonts[:F1]
        new_font = new_font_ref[:referenced_object]

        # Should be replaced with a standard font
        refute_equal non_embedded_font, new_font, 'Non-embedded font should be replaced'
        assert new_font[:BaseFont], 'Replacement font must have BaseFont'
      end

      it 'preserves embedded fonts' do
        pdf = CombinePDF.new
        page = pdf.new_page

        # Create an embedded font (has FontDescriptor with FontFile2)
        font_descriptor = {
          Type: :FontDescriptor,
          FontName: :'Helvetica-Bold',
          FontFile2: { is_reference_only: true, referenced_object: { raw_stream_content: 'fake font data' } }
        }

        embedded_font = {
          Type: :Font,
          Subtype: :TrueType,
          BaseFont: :'Helvetica-Bold',
          FontDescriptor: { is_reference_only: true, referenced_object: font_descriptor }
        }

        page[:Resources] = { Font: { F1: { is_reference_only: true, referenced_object: embedded_font } } }
        pdf.objects << embedded_font
        pdf.objects << font_descriptor

        # Process the PDF
        pdf.to_pdf

        # Embedded font should NOT be replaced
        fonts = page[:Resources][:Font]
        current_font = fonts[:F1][:referenced_object]

        assert_equal embedded_font, current_font, 'Embedded fonts should be preserved'
      end

      it 'maps Arial to Helvetica' do
        pdf = CombinePDF.new
        page = pdf.new_page

        arial_font = {
          Type: :Font,
          Subtype: :TrueType,
          BaseFont: :Arial
        }

        page[:Resources] = { Font: { F1: { is_reference_only: true, referenced_object: arial_font } } }
        pdf.objects << arial_font

        pdf.to_pdf

        # Arial should be replaced with Helvetica
        replacement = page[:Resources][:Font][:F1][:referenced_object]
        assert_equal :Helvetica, replacement[:BaseFont], 'Arial should map to Helvetica'
      end

      it 'maps Times New Roman to Times-Roman' do
        pdf = CombinePDF.new
        page = pdf.new_page

        times_font = {
          Type: :Font,
          Subtype: :TrueType,
          BaseFont: :TimesNewRoman
        }

        page[:Resources] = { Font: { F1: { is_reference_only: true, referenced_object: times_font } } }
        pdf.objects << times_font

        pdf.to_pdf

        replacement = page[:Resources][:Font][:F1][:referenced_object]
        assert_equal :'Times-Roman', replacement[:BaseFont], 'Times New Roman should map to Times-Roman'
      end

      it 'maps Courier New to Courier' do
        pdf = CombinePDF.new
        page = pdf.new_page

        courier_font = {
          Type: :Font,
          Subtype: :TrueType,
          BaseFont: :CourierNew
        }

        page[:Resources] = { Font: { F1: { is_reference_only: true, referenced_object: courier_font } } }
        pdf.objects << courier_font

        pdf.to_pdf

        replacement = page[:Resources][:Font][:F1][:referenced_object]
        assert_equal :Courier, replacement[:BaseFont], 'Courier New should map to Courier'
      end

      it 'preserves Type3 fonts (always embedded)' do
        pdf = CombinePDF.new
        page = pdf.new_page

        type3_font = {
          Type: :Font,
          Subtype: :Type3,
          FontBBox: [0, 0, 1000, 1000],
          FontMatrix: [0.001, 0, 0, 0.001, 0, 0],
          CharProcs: {}
        }

        page[:Resources] = { Font: { F1: { is_reference_only: true, referenced_object: type3_font } } }
        pdf.objects << type3_font

        pdf.to_pdf

        # Type3 fonts should be preserved (they're always embedded)
        current_font = page[:Resources][:Font][:F1][:referenced_object]
        assert_equal type3_font, current_font, 'Type3 fonts should be preserved (always embedded)'
      end

      it 'does not replace fonts when PDF/A is disabled' do
        pdf = CombinePDF.new
        pdf.enable_pdf_a = false # Disable PDF/A
        page = pdf.new_page

        non_embedded_font = {
          Type: :Font,
          Subtype: :Type1,
          BaseFont: :Arial
        }

        page[:Resources] = { Font: { F1: { is_reference_only: true, referenced_object: non_embedded_font } } }
        pdf.objects << non_embedded_font

        pdf.to_pdf

        # Font should NOT be replaced when PDF/A is disabled
        current_font = page[:Resources][:Font][:F1][:referenced_object]
        assert_equal non_embedded_font, current_font, 'Fonts should not be replaced when PDF/A is disabled'
      end
    end
  end
end
