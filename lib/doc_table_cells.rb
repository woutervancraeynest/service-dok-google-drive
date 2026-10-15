# Pure helpers for cell-targeted table edits in Google Docs.
# No network calls; all methods operate on the structure produced by
# DocTables.parse.
#
# Agents identify cells with semantic selectors (table context, row label,
# column header, anchor text) or with a stable cell_id returned by the
# inspection tool. Docs API indices never leave this service.
module DocTableCells
  DEFAULT_PLACEHOLDERS = [
    "Klik of tik om tekst in te voeren.",
    "Klik of tik hier om tekst in te voeren.",
    "Klik of tik om een datum in te voeren.",
    "Klik hier als u tekst wilt invoeren.",
    "Klik hier als u een datum wilt invoeren.",
    "Kies een item.",
    "Click or tap here to enter text.",
    "Click or tap to enter a date.",
    "Click here to enter text.",
    "Click here to enter a date.",
    "Choose an item."
  ].freeze
  FILLER_ONLY = /\A[\s_.…]*\z/.freeze
  RELATIONS = %w[right below next].freeze
  MAX_CANDIDATES = 10
  MAX_CELL_TEXT = 300

  class << self
    # ── Normalisation ────────────────────────────────────────────────

    # Matching form: Unicode NFC, non-breaking spaces and soft line breaks
    # as spaces, collapsed whitespace, case-insensitive, trailing colon ignored.
    def normalize(text)
      text.to_s.unicode_normalize(:nfc)
        .tr("\u00A0\u000B\u2007\u202F", "    ")
        .gsub(/\s+/, " ").strip.downcase
        .sub(/\s*:\z/, "")
    end

    # Comparison form for cell content: keeps case and inner line breaks.
    def clean_value(text)
      text.to_s.unicode_normalize(:nfc)
        .gsub("\r\n", "\n").tr("\u000B", "\n")
        .sub(/\n+\z/, "").strip
    end

    # ── Identifiers ──────────────────────────────────────────────────

    def table_id(tab_id, table_index)
      "#{tab_id || 'body'}/#{table_index}"
    end

    def cell_id(tab_id, table_index, row_index, column_index)
      "#{table_id(tab_id, table_index)}/#{row_index}/#{column_index}"
    end

    # "t.0/2/1/1" -> { table_id: "t.0/2", row_index: 1, column_index: 1 }
    def parse_cell_id(value)
      parts = value.to_s.strip.split("/")
      return nil unless parts.length == 4 && parts[1..].all? { |p| p.match?(/\A\d+\z/) }

      { table_id: "#{parts[0]}/#{parts[1]}", row_index: parts[2].to_i, column_index: parts[3].to_i }
    end

    # ── Cell state ───────────────────────────────────────────────────

    # "empty", "placeholder" or "filled".
    def cell_state(cell, placeholders: [])
      return "filled" if cell[:nested_table] || cell[:suggestions] || cell[:rich_elements].to_i.positive?

      text = clean_value(cell[:text])
      return "empty" if text.match?(FILLER_ONLY)
      return "placeholder" if placeholder_text?(text, placeholders)

      "filled"
    end

    def placeholder_text?(text, extra = [])
      return true if text.match?(DocTables::PLACEHOLDER_TOKEN)

      target = placeholder_key(text)
      (DEFAULT_PLACEHOLDERS + Array(extra)).any? { |p| placeholder_key(p) == target }
    end

    # ── Table filtering ──────────────────────────────────────────────

    # Returns [{ tab_id:, table: }] for every table matching all given
    # selector keys. An empty selector matches every table.
    def filter_tables(parsed_tabs, selector)
      selector = symbolize(selector)
      all_tables(parsed_tabs).select { |entry| table_matches?(entry, selector) }
    end

    def all_tables(parsed_tabs)
      parsed_tabs.flat_map do |tab|
        tab[:tables].map { |table| { tab_id: tab[:tab_id], table: table } }
      end
    end

    def table_label(table)
      table[:section_heading] || first_cell_text(table) || table[:preceding_text]
    end

    # ── Resolution ───────────────────────────────────────────────────

    # Resolves selectors to exactly one cell.
    # Returns { status: "resolved", target: {...} } or a failure hash
    # { status:, message:, candidates: [...] }.
    def resolve(parsed_tabs, table_selector: nil, row_selector: nil, column_selector: nil, cell_selector: nil)
      table_selector = symbolize(table_selector)
      row_selector = symbolize(row_selector)
      column_selector = symbolize(column_selector)
      cell_selector = symbolize(cell_selector)

      error = validate_selectors(table_selector, row_selector, column_selector, cell_selector)
      return failure("invalid_selector", error) if error

      tables = filter_tables(parsed_tabs, table_selector)
      if tables.empty?
        return failure("table_not_found", "No table matches the table selector.",
                       available_tables: table_summaries(parsed_tabs))
      end

      if cell_selector[:cell_id]
        resolve_by_cell_id(tables, cell_selector[:cell_id])
      elsif cell_selector[:anchor_text]
        resolve_by_anchor(tables, cell_selector[:anchor_text], cell_selector.fetch(:relation, "next"))
      else
        resolve_by_grid(tables, row_selector, column_selector)
      end
    end

    # ── Inspection ───────────────────────────────────────────────────

    def inspect_tables(parsed_tabs, table_selector: nil, placeholders: [])
      filter_tables(parsed_tabs, table_selector).map do |entry|
        table = entry[:table]
        {
          table_id: table_id(entry[:tab_id], table[:table_index]),
          tab_id: entry[:tab_id],
          label: truncate(table_label(table)),
          section_heading: truncate(table[:section_heading]),
          preceding_text: truncate(table[:preceding_text]),
          row_count: table[:rows].length,
          column_count: table[:columns] || table[:rows].map { |r| r[:cells].length }.max.to_i,
          rows: table[:rows].map do |row|
            {
              row_index: row[:row_index],
              cells: row[:cells].map do |cell|
                {
                  cell_id: cell_id(entry[:tab_id], table[:table_index], row[:row_index], cell[:column_index]),
                  column_index: cell[:column_index],
                  text: truncate(clean_value(cell[:text])),
                  state: cell_state(cell, placeholders: placeholders),
                  has_suggestions: cell[:suggestions] ? true : nil
                }.compact
              end
            }
          end
        }
      end
    end

    # ── Verification ─────────────────────────────────────────────────

    # Confirms that after a write only the target cell changed and that it
    # now holds +value+. Returns { ok:, checks:, problems: }.
    def verify_update(before_tabs, after_tabs, target, value)
      problems = []
      after_target = locate(after_tabs, target[:tab_id], target[:table][:table_index],
                            target[:row_index], target[:column_index])

      value_ok = after_target && clean_value(after_target[:text]) == clean_value(value)
      problems << "Target cell does not contain the new value." unless value_ok

      structure_ok = structure_signature(before_tabs) == structure_signature(after_tabs)
      problems << "Table structure changed (tables, rows or columns)." unless structure_ok

      before_cells = cell_texts(before_tabs, except: target)
      after_cells = cell_texts(after_tabs, except: target)
      others_ok = before_cells == after_cells
      problems << "Other table cells changed." unless others_ok

      outside_ok = outside_texts(before_tabs) == outside_texts(after_tabs)
      problems << "Text outside tables changed." unless outside_ok

      {
        ok: problems.empty?,
        checks: {
          target_has_value: !!value_ok,
          structure_unchanged: structure_ok,
          other_cells_unchanged: others_ok,
          text_outside_tables_unchanged: outside_ok
        },
        problems: problems
      }
    end

    def locate(parsed_tabs, tab_id, table_index, row_index, column_index)
      tab = parsed_tabs.find { |t| t[:tab_id] == tab_id }
      table = tab && tab[:tables][table_index]
      row = table && table[:rows][row_index]
      row && row[:cells][column_index]
    end

    def describe_target(target)
      {
        cell_id: cell_id(target[:tab_id], target[:table][:table_index], target[:row_index], target[:column_index]),
        table_id: table_id(target[:tab_id], target[:table][:table_index]),
        table: truncate(table_label(target[:table])),
        row: truncate(target[:row_label]),
        row_index: target[:row_index],
        column: truncate(target[:column_label]),
        column_index: target[:column_index],
        current_value: truncate(clean_value(target[:cell][:text]))
      }
    end

    private

    def validate_selectors(table_selector, row_selector, column_selector, cell_selector)
      if cell_selector.any?
        if row_selector.any? || column_selector.any?
          return "Use either cell_selector or row_selector + column_selector, not both."
        end
        if cell_selector[:cell_id] && cell_selector[:anchor_text]
          return "cell_selector accepts either cell_id or anchor_text, not both."
        end
        if !cell_selector[:cell_id] && blank?(cell_selector[:anchor_text])
          return "cell_selector requires cell_id or anchor_text."
        end
        relation = cell_selector.fetch(:relation, "next").to_s
        return "relation must be one of: #{RELATIONS.join(', ')}." unless RELATIONS.include?(relation)
        return nil
      end

      if blank?(row_selector[:cell_text]) && row_selector[:row_index].nil?
        return "row_selector requires cell_text or row_index."
      end
      if blank?(column_selector[:header_text]) && column_selector[:index].nil?
        return "column_selector requires header_text or index."
      end
      if table_selector.empty? && blank?(row_selector[:cell_text])
        return "A table_selector is required when the row is selected by row_index."
      end

      nil
    end

    def resolve_by_cell_id(tables, raw_id)
      parsed = parse_cell_id(raw_id)
      return failure("invalid_selector", "cell_id has an invalid format.") unless parsed

      entry = tables.find { |e| table_id(e[:tab_id], e[:table][:table_index]) == parsed[:table_id] }
      return failure("table_not_found", "No table with id #{parsed[:table_id]} matches the selectors.") unless entry

      row = entry[:table][:rows][parsed[:row_index]]
      return failure("row_not_found", "Row #{parsed[:row_index]} does not exist in this table.") unless row

      cell = row[:cells][parsed[:column_index]]
      return failure("column_not_found", "Column #{parsed[:column_index]} does not exist in this row.") unless cell

      resolved(build_target(entry, parsed[:row_index], parsed[:column_index], column_label: nil))
    end

    def resolve_by_anchor(tables, anchor_text, relation)
      anchor = normalize(anchor_text)
      anchors = []
      tables.each do |entry|
        entry[:table][:rows].each do |row|
          row[:cells].each do |cell|
            anchors << [entry, row[:row_index], cell[:column_index]] if normalize(cell[:text]) == anchor
          end
        end
      end

      return failure("cell_not_found", "No cell with text '#{anchor_text}' was found.") if anchors.empty?

      targets = anchors.filter_map do |entry, row_index, column_index|
        position = related_position(entry[:table], row_index, column_index, relation.to_s)
        position && build_target(entry, *position, column_label: nil, row_label: anchor_text)
      end

      if anchors.length > 1
        return failure("ambiguous_match", "#{anchors.length} cells contain the anchor text '#{anchor_text}'.",
                       candidates: targets.first(MAX_CANDIDATES).map { |t| describe_target(t) })
      end
      return failure("cell_not_found", "The anchor cell has no '#{relation}' cell.") if targets.empty?

      resolved(targets.first)
    end

    def related_position(table, row_index, column_index, relation)
      rows = table[:rows]
      case relation
      when "right"
        [row_index, column_index + 1] if rows[row_index][:cells][column_index + 1]
      when "below"
        [row_index + 1, column_index] if rows[row_index + 1]&.dig(:cells, column_index)
      when "next"
        if rows[row_index][:cells][column_index + 1]
          [row_index, column_index + 1]
        elsif rows[row_index + 1]&.dig(:cells, 0)
          [row_index + 1, 0]
        end
      end
    end

    def resolve_by_grid(tables, row_selector, column_selector)
      match_column = row_selector.fetch(:column_index, 0).to_i
      row_matches = tables.flat_map do |entry|
        entry[:table][:rows].select { |row| row_matches?(row, row_selector, match_column) }
                            .map { |row| [entry, row] }
      end
      return failure("row_not_found", "No row matches the row selector.") if row_matches.empty?

      targets = []
      column_ambiguities = []
      row_matches.each do |entry, row|
        columns = resolve_columns(entry[:table], row, column_selector)
        column_ambiguities << [entry, row, columns] if columns.length > 1
        columns.each do |column_index, label|
          targets << build_target(entry, row[:row_index], column_index, column_label: label,
                                  row_label_column: match_column)
        end
      end

      if targets.empty?
        return failure("column_not_found", "The matched row has no cell in the selected column.",
                       candidates: row_matches.first(MAX_CANDIDATES).map { |e, r| describe_row(e, r) })
      end
      if targets.length > 1
        reason = column_ambiguities.any? ? "column header matches multiple columns" : "multiple rows match"
        return failure("ambiguous_match", "Selectors match #{targets.length} cells (#{reason}).",
                       candidates: targets.first(MAX_CANDIDATES).map { |t| describe_target(t) })
      end

      target = targets.first
      if target[:column_index] == match_column && !blank?(row_selector[:cell_text])
        return failure("invalid_selector", "The selected column is the row label column itself.")
      end

      resolved(target)
    end

    def row_matches?(row, row_selector, match_column)
      if !row_selector[:row_index].nil? && row[:row_index] != row_selector[:row_index].to_i
        return false
      end
      return true if blank?(row_selector[:cell_text])

      cell = row[:cells][match_column]
      cell && normalize(cell[:text]) == normalize(row_selector[:cell_text])
    end

    # Returns [[column_index, label], ...] for the target row.
    def resolve_columns(table, row, column_selector)
      index = column_selector[:index]&.to_i
      header = column_selector[:header_text]

      if blank?(header)
        return row[:cells][index] ? [[index, nil]] : []
      end

      header_rows = header_row_candidates(table, row, column_selector[:header_row_index])
      wanted = normalize(header)
      header_rows.each do |header_row|
        columns = header_row[:cells].select { |c| normalize(c[:text]) == wanted }.map { |c| c[:column_index] }
        next if columns.empty?

        columns &= [index] if index
        return columns.select { |c| row[:cells][c] }.map { |c| [c, clean_value(header)] }
      end
      []
    end

    # Header rows are searched upward from the target row, nearest first,
    # so title rows above the real header row do not interfere.
    def header_row_candidates(table, row, header_row_index)
      unless header_row_index.nil?
        header_row = table[:rows][header_row_index.to_i]
        return header_row && header_row[:row_index] < row[:row_index] ? [header_row] : []
      end

      table[:rows].first(row[:row_index]).reverse
    end

    def build_target(entry, row_index, column_index, column_label:, row_label: nil, row_label_column: 0)
      table = entry[:table]
      row = table[:rows][row_index]
      row_label ||= clean_value(row[:cells][row_label_column]&.dig(:text))
      {
        tab_id: entry[:tab_id],
        table: table,
        row_index: row_index,
        column_index: column_index,
        cell: row[:cells][column_index],
        row_label: row_label,
        column_label: column_label || column_index.to_s
      }
    end

    def describe_row(entry, row)
      {
        table_id: table_id(entry[:tab_id], entry[:table][:table_index]),
        table: truncate(table_label(entry[:table])),
        row_index: row[:row_index],
        cells: row[:cells].map { |c| truncate(clean_value(c[:text])) }
      }
    end

    def table_matches?(entry, selector)
      table = entry[:table]

      if selector[:table_id] && table_id(entry[:tab_id], table[:table_index]) != selector[:table_id].to_s
        return false
      end

      if selector[:header_cells].is_a?(Array) && selector[:header_cells].any?
        wanted = selector[:header_cells].map { |h| normalize(h) }
        return false unless table[:rows].any? { |row| row[:cells].map { |c| normalize(c[:text]) } == wanted }
      end

      unless blank?(selector[:section_heading])
        wanted = normalize(selector[:section_heading])
        context = [table[:section_heading], table[:preceding_text], first_cell_text(table)]
        return false unless context.compact.any? { |text| normalize(text) == wanted }
      end

      unless blank?(selector[:contains_text])
        wanted = normalize(selector[:contains_text])
        return false unless table[:rows].any? { |row| row[:cells].any? { |c| normalize(c[:text]) == wanted } }
      end

      true
    end

    def table_summaries(parsed_tabs)
      all_tables(parsed_tabs).first(20).map do |entry|
        table = entry[:table]
        {
          table_id: table_id(entry[:tab_id], table[:table_index]),
          label: truncate(table_label(table)),
          first_row: Array(table[:rows].first&.dig(:cells)).map { |c| truncate(clean_value(c[:text])) }
        }
      end
    end

    def first_cell_text(table)
      text = clean_value(table[:rows].first&.dig(:cells, 0, :text))
      text.empty? ? nil : text
    end

    def structure_signature(parsed_tabs)
      parsed_tabs.map do |tab|
        [tab[:tab_id], tab[:tables].map { |t| t[:rows].map { |r| r[:cells].length } }]
      end
    end

    def cell_texts(parsed_tabs, except:)
      parsed_tabs.flat_map do |tab|
        tab[:tables].flat_map do |table|
          table[:rows].flat_map do |row|
            row[:cells].filter_map do |cell|
              skip = tab[:tab_id] == except[:tab_id] && table[:table_index] == except[:table][:table_index] &&
                     row[:row_index] == except[:row_index] && cell[:column_index] == except[:column_index]
              [tab[:tab_id], table[:table_index], row[:row_index], cell[:column_index], cell[:text]] unless skip
            end
          end
        end
      end
    end

    def outside_texts(parsed_tabs)
      parsed_tabs.map { |tab| [tab[:tab_id], tab[:outside_paragraphs].map { |p| p[:text] }] }
    end

    def placeholder_key(text)
      normalize(text).sub(/[.…]+\z/, "")
    end

    def resolved(target)
      { status: "resolved", target: target }
    end

    def failure(status, message, **extra)
      { status: status, message: message }.merge(extra)
    end

    def truncate(text)
      return nil if text.nil?

      text.length > MAX_CELL_TEXT ? "#{text[0, MAX_CELL_TEXT]}…" : text
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def symbolize(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
    end
  end
end
