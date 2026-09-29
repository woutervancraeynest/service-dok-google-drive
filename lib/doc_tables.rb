# Pure helpers for structural table operations in Google Docs.
# No network calls; all methods operate on parsed document structures.
#
# The parse method expects a Document object returned by the Docs API
# with include_tabs_content: true.  It produces a simple array-of-hashes
# structure that every other method in this module consumes.
module DocTables
  DATE_PATTERN = /\b\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{4}\b/.freeze
  PLACEHOLDER_TOKEN = /\A<[^>]+>\z/.freeze

  class << self
    # ── Parsing ────────────────────────────────────────────────────────

    # Returns an array of tab hashes:
    #   [{ tab_id:, tables: [...], outside_paragraphs: [...] }, ...]
    def parse(document)
      tabs = collect_tabs(document)
      return [parse_legacy_body(document)] if tabs.empty?

      tabs.map { |tab| parse_tab(tab) }
    end

    # ── Table lookup ───────────────────────────────────────────────────

    # Returns { tab_id:, table: } for the first table whose header row
    # matches +header_cells+ (case-insensitive, whitespace-normalised),
    # or nil when no match is found.
    def find_table(parsed_tabs, header_cells)
      target = header_cells.map { |h| normalize_header(h) }
      parsed_tabs.each do |tab|
        tab[:tables].each do |table|
          next if table[:rows].empty?
          row_headers = table[:rows][0][:cells].map { |c| normalize_header(c[:text]) }
          return { tab_id: tab[:tab_id], table: table } if row_headers == target
        end
      end
      nil
    end

    # ── Date helpers ───────────────────────────────────────────────────

    # Normalise a date string to dd/mm/yyyy.
    # Tolerates d/m/yyyy, dd-mm-yyyy, dd.mm.yyyy.
    # Returns nil for unparseable input.
    def normalize_date(str)
      return nil if str.nil?

      cleaned = str.to_s.strip
      return nil if cleaned.empty?

      match = cleaned.match(/\A(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{4})\z/)
      return nil unless match

      day, month, year = match[1].to_i, match[2].to_i, match[3].to_i
      return nil if day < 1 || day > 31 || month < 1 || month > 12

      format("%02d/%02d/%04d", day, month, year)
    end

    # ── Deduplication ──────────────────────────────────────────────────

    # Returns the row_index of the first data row where the cell at
    # +column_index+ matches +value+ using the given +match+ mode,
    # or nil when no match is found.
    #
    # match modes:
    #   "date"  — normalise both sides as dd/mm/yyyy, then compare
    #   "exact" — strip whitespace, compare literally
    #   "none"/nil — always returns nil (no dedup)
    def duplicate_row_index(table, column_index:, value:, match:)
      return nil if match.nil? || match == "none"

      table[:rows].each_with_index do |row, idx|
        next if idx == 0 # skip header
        next if row[:cells].empty?

        cell = row[:cells][column_index]
        next unless cell

        return idx if column_matches?(cell[:text], value, match)
      end
      nil
    end

    # ── Placeholder detection ──────────────────────────────────────────

    # If the table has exactly one data row and every cell in that row
    # is either blank or a <token> placeholder, return its row_index (1).
    # Otherwise nil.
    def placeholder_row_index(table)
      data_rows = table[:rows][1..]
      return nil unless data_rows && data_rows.length == 1

      row = data_rows[0]
      all_placeholder = row[:cells].all? do |cell|
        text = cell[:text].to_s.strip
        text.empty? || text.match?(PLACEHOLDER_TOKEN)
      end
      all_placeholder ? 1 : nil
    end

    # ── Outside-text helpers ───────────────────────────────────────────

    # Outside-table paragraphs whose text contains a date pattern.
    # Used by the analysis tool for informational reporting.
    def dated_paragraphs(parsed_tab)
      return [] unless parsed_tab

      parsed_tab[:outside_paragraphs].select do |para|
        para[:text].match?(DATE_PATTERN)
      end
    end

    # ── Verification ───────────────────────────────────────────────────

    # Compare before/after parsed states to confirm the append succeeded.
    # +cells+ is the array of values that were written.
    # +dedup+ is an optional hash { column_index:, match: } or nil.
    def verify(before_tab, after_tab, before_table, after_table, cells, dedup: nil)
      result = {
        row_found: false,
        previous_rows_intact: true,
        text_added_outside_table: false
      }
      warnings = []

      # 1. New row must exist
      result[:row_found] = row_present?(after_table, cells, dedup)
      warnings << "Row not found after update." unless result[:row_found]

      # 2. Existing non-placeholder data rows must be unchanged
      before_data = non_placeholder_rows(before_table)
      after_data = after_table[:rows][1..] || []

      before_data.each_with_index do |before_row, idx|
        after_row = after_data[idx]
        if after_row.nil?
          result[:previous_rows_intact] = false
          warnings << "Previously existing row #{idx + 1} is missing."
          break
        end
        if before_row[:cells].map { |c| c[:text] } != after_row[:cells].map { |c| c[:text] }
          result[:previous_rows_intact] = false
          warnings << "Row #{idx + 1} content changed."
          break
        end
      end

      # 3. No new text outside the table
      before_outside = before_tab[:outside_paragraphs].map { |p| p[:text] }.sort
      after_outside = after_tab[:outside_paragraphs].map { |p| p[:text] }.sort
      if (after_outside - before_outside).any?
        result[:text_added_outside_table] = true
        warnings << "New text appeared outside the table."
      end

      # 4. Dedup value uniqueness
      if dedup && dedup[:match] && dedup[:match] != "none"
        col = dedup[:column_index]
        val = cells[col]
        count = (after_table[:rows][1..] || []).count do |row|
          !row[:cells].empty? && row[:cells][col] && column_matches?(row[:cells][col][:text], val, dedup[:match])
        end
        warnings << "Dedup value appears #{count} times in column #{col}." if count > 1
      end

      { verification: result, warnings: warnings }
    end

    private

    # ── Tab collection ─────────────────────────────────────────────────

    def collect_tabs(document)
      result = []
      Array(document.tabs).each { |tab| collect_tabs_recursive(tab, result) }
      result
    end

    def collect_tabs_recursive(tab, result)
      result << tab
      Array(tab.child_tabs).each { |child| collect_tabs_recursive(child, result) }
    end

    # ── Body parsing ───────────────────────────────────────────────────

    def parse_tab(tab)
      tab_id = tab.tab_properties&.tab_id
      body_content = Array(tab.document_tab&.body&.content)
      parse_body_content(tab_id, body_content)
    end

    def parse_legacy_body(document)
      parse_body_content(nil, Array(document.body&.content))
    end

    def parse_body_content(tab_id, elements)
      tables = []
      outside_paragraphs = []

      elements.each do |element|
        if element.respond_to?(:table) && element.table
          tables << parse_table_element(element)
        elsif element.respond_to?(:paragraph) && element.paragraph
          text = paragraph_text(element.paragraph)
          next if text.strip.empty?

          outside_paragraphs << {
            text: text,
            start_index: element.start_index,
            end_index: element.end_index
          }
        end
      end

      { tab_id: tab_id, tables: tables, outside_paragraphs: outside_paragraphs }
    end

    def parse_table_element(element)
      table = element.table
      rows = Array(table.table_rows).each_with_index.map do |row, row_idx|
        cells = Array(row.table_cells).each_with_index.map do |cell, col_idx|
          {
            column_index: col_idx,
            start_index: cell.start_index,
            end_index: cell.end_index,
            text: cell_text(cell)
          }
        end
        { row_index: row_idx, cells: cells }
      end

      {
        start_index: element.start_index,
        end_index: element.end_index,
        rows: rows,
        columns: table.columns
      }
    end

    # ── Text extraction ────────────────────────────────────────────────

    def cell_text(cell)
      Array(cell.content).filter_map do |el|
        paragraph_text(el.paragraph) if el.respond_to?(:paragraph) && el.paragraph
      end.join
    end

    def paragraph_text(paragraph)
      return "" unless paragraph

      Array(paragraph.elements).filter_map { |el| el.text_run&.content }.join
    end

    def normalize_header(text)
      text.to_s.strip.downcase.gsub(/\s+/, " ")
    end

    def non_placeholder_rows(table)
      (table[:rows][1..] || []).reject do |row|
        row[:cells].all? do |cell|
          text = cell[:text].to_s.strip
          text.empty? || text.match?(PLACEHOLDER_TOKEN)
        end
      end
    end

    # ── Match helpers ──────────────────────────────────────────────────

    def column_matches?(cell_text, value, match_mode)
      case match_mode
      when "date"
        a = normalize_date(cell_text)
        b = normalize_date(value)
        a && b && a == b
      when "exact"
        cell_text.to_s.strip == value.to_s.strip
      else
        false
      end
    end

    def row_present?(table, cells, dedup)
      if dedup && dedup[:match] && dedup[:match] != "none"
        col = dedup[:column_index]
        val = cells[col]
        (table[:rows][1..] || []).any? do |row|
          !row[:cells].empty? && row[:cells][col] && column_matches?(row[:cells][col][:text], val, dedup[:match])
        end
      else
        (table[:rows][1..] || []).any? do |row|
          next false if row[:cells].empty?
          cells.each_with_index.all? do |value, ci|
            cell = row[:cells][ci]
            cell && cell[:text].to_s.strip == value.to_s.strip
          end
        end
      end
    end
  end
end
