require "spec_helper"

RSpec.describe DocTables do
  # ── Fixture helpers ──────────────────────────────────────────────

  def text_run(content)
    OpenStruct.new(text_run: OpenStruct.new(content: content))
  end

  def paragraph(*texts)
    OpenStruct.new(elements: texts.map { |t| text_run(t) })
  end

  def structural_paragraph(text, start_index:, end_index:)
    OpenStruct.new(
      start_index: start_index, end_index: end_index,
      paragraph: paragraph(text), table: nil
    )
  end

  def table_cell(text, start_index:, end_index:)
    # Realistic: content paragraph starts 1 past the cell boundary
    content_start = start_index + 1
    OpenStruct.new(
      start_index: start_index, end_index: end_index,
      content: [OpenStruct.new(
        start_index: content_start, end_index: end_index,
        paragraph: paragraph(text), table: nil
      )]
    )
  end

  def table_row(*cells)
    OpenStruct.new(table_cells: cells)
  end

  def structural_table(rows, start_index:, end_index:, columns: nil)
    columns ||= rows.first&.table_cells&.length || 0
    OpenStruct.new(
      start_index: start_index, end_index: end_index,
      table: OpenStruct.new(table_rows: rows, columns: columns),
      paragraph: nil
    )
  end

  def tab_with_content(tab_id, *elements)
    OpenStruct.new(
      tab_properties: OpenStruct.new(tab_id: tab_id),
      document_tab: OpenStruct.new(body: OpenStruct.new(content: elements)),
      child_tabs: []
    )
  end

  def document_with_tabs(*tabs)
    OpenStruct.new(tabs: tabs, body: nil, revision_id: "rev-1")
  end

  # ── Standard logbook table ──────────────────────────────────────

  def logbook_header_row
    table_row(
      table_cell("Datum\n", start_index: 3, end_index: 10),
      table_cell("Inhoud van het contact\n", start_index: 11, end_index: 34),
      table_cell("To do\n", start_index: 35, end_index: 42)
    )
  end

  # ── Two-column generic table ────────────────────────────────────

  def generic_header_row
    table_row(
      table_cell("Name\n", start_index: 3, end_index: 9),
      table_cell("Email\n", start_index: 10, end_index: 17)
    )
  end

  let(:logbook_headers) { ["Datum", "Inhoud van het contact", "To do"] }
  let(:generic_headers) { ["Name", "Email"] }

  # ── parse ────────────────────────────────────────────────────────

  describe ".parse" do
    it "extracts tables and outside paragraphs from a tabbed document" do
      table = structural_table([logbook_header_row], start_index: 2, end_index: 43)
      para = structural_paragraph("Titel\n", start_index: 0, end_index: 2)
      tab = tab_with_content("t.0", para, table)
      doc = document_with_tabs(tab)

      result = DocTables.parse(doc)

      expect(result.length).to eq(1)
      expect(result[0][:tab_id]).to eq("t.0")
      expect(result[0][:tables].length).to eq(1)
      expect(result[0][:outside_paragraphs].length).to eq(1)
    end

    it "handles child tabs recursively" do
      child_table = structural_table([logbook_header_row], start_index: 2, end_index: 43)
      child = tab_with_content("t.child", child_table)
      parent = OpenStruct.new(
        tab_properties: OpenStruct.new(tab_id: "t.parent"),
        document_tab: OpenStruct.new(body: OpenStruct.new(content: [])),
        child_tabs: [child]
      )
      doc = document_with_tabs(parent)

      result = DocTables.parse(doc)

      expect(result.length).to eq(2)
      expect(result.map { |t| t[:tab_id] }).to eq(["t.parent", "t.child"])
    end

    it "falls back to legacy body when tabs are empty" do
      body_element = OpenStruct.new(
        start_index: 0, end_index: 6,
        paragraph: paragraph("Hello\n"), table: nil
      )
      doc = OpenStruct.new(tabs: [], body: OpenStruct.new(content: [body_element]), revision_id: "rev-1")

      result = DocTables.parse(doc)

      expect(result.length).to eq(1)
      expect(result[0][:tab_id]).to be_nil
    end
  end

  # ── find_table ───────────────────────────────────────────────────

  describe ".find_table" do
    it "matches a table by header cells" do
      table = structural_table([logbook_header_row], start_index: 2, end_index: 43)
      tab = tab_with_content("t.0", table)
      parsed = DocTables.parse(document_with_tabs(tab))

      expect(DocTables.find_table(parsed, logbook_headers)).not_to be_nil
    end

    it "matches a two-column generic table" do
      table = structural_table([generic_header_row], start_index: 2, end_index: 18, columns: 2)
      tab = tab_with_content("t.0", table)
      parsed = DocTables.parse(document_with_tabs(tab))

      expect(DocTables.find_table(parsed, generic_headers)).not_to be_nil
    end

    it "matches case-insensitively and normalises whitespace" do
      row = table_row(
        table_cell("datum\n", start_index: 3, end_index: 10),
        table_cell("  inhoud van het  contact \n", start_index: 11, end_index: 40),
        table_cell("TO DO\n", start_index: 41, end_index: 48)
      )
      table = structural_table([row], start_index: 2, end_index: 49)
      tab = tab_with_content("t.0", table)
      parsed = DocTables.parse(document_with_tabs(tab))

      expect(DocTables.find_table(parsed, logbook_headers)).not_to be_nil
    end

    it "returns nil when no table matches" do
      table = structural_table([generic_header_row], start_index: 2, end_index: 18, columns: 2)
      tab = tab_with_content("t.0", table)
      parsed = DocTables.parse(document_with_tabs(tab))

      expect(DocTables.find_table(parsed, logbook_headers)).to be_nil
    end

    it "searches across tabs" do
      tab1 = tab_with_content("t.1")
      table = structural_table([logbook_header_row], start_index: 2, end_index: 43)
      tab2 = tab_with_content("t.2", table)
      parsed = DocTables.parse(document_with_tabs(tab1, tab2))

      expect(DocTables.find_table(parsed, logbook_headers)[:tab_id]).to eq("t.2")
    end
  end

  # ── normalize_date ───────────────────────────────────────────────

  describe ".normalize_date" do
    it "normalises dd/mm/yyyy" do
      expect(DocTables.normalize_date("11/09/2026")).to eq("11/09/2026")
    end

    it "pads single-digit day and month" do
      expect(DocTables.normalize_date("1/9/2026")).to eq("01/09/2026")
    end

    it "accepts dash and dot separators" do
      expect(DocTables.normalize_date("11-09-2026")).to eq("11/09/2026")
      expect(DocTables.normalize_date("11.09.2026")).to eq("11/09/2026")
    end

    it "returns nil for empty or non-date input" do
      expect(DocTables.normalize_date("")).to be_nil
      expect(DocTables.normalize_date(nil)).to be_nil
      expect(DocTables.normalize_date("not a date")).to be_nil
    end

    it "returns nil for invalid months or days" do
      expect(DocTables.normalize_date("01/13/2026")).to be_nil
      expect(DocTables.normalize_date("32/01/2026")).to be_nil
    end

    it "strips surrounding whitespace and newlines" do
      expect(DocTables.normalize_date("  11/09/2026  ")).to eq("11/09/2026")
      expect(DocTables.normalize_date("11/09/2026\n")).to eq("11/09/2026")
    end
  end

  # ── duplicate_row_index ──────────────────────────────────────────

  describe ".duplicate_row_index" do
    it "returns nil with match mode none" do
      table = build_parsed_table(["11/09/2026", "A", "B"])

      expect(DocTables.duplicate_row_index(table, column_index: 0, value: "11/09/2026", match: "none")).to be_nil
      expect(DocTables.duplicate_row_index(table, column_index: 0, value: "11/09/2026", match: nil)).to be_nil
    end

    it "finds a duplicate by date normalisation" do
      table = build_parsed_table(["1/9/2026", "A", "B"], ["11/09/2026", "C", "D"])

      expect(DocTables.duplicate_row_index(table, column_index: 0, value: "01/09/2026", match: "date")).to eq(1)
      expect(DocTables.duplicate_row_index(table, column_index: 0, value: "11/09/2026", match: "date")).to eq(2)
    end

    it "finds a duplicate by exact match" do
      table = build_parsed_table(["Alice", "alice@example.com"], ["Bob", "bob@example.com"])

      expect(DocTables.duplicate_row_index(table, column_index: 0, value: "Alice", match: "exact")).to eq(1)
      expect(DocTables.duplicate_row_index(table, column_index: 1, value: "bob@example.com", match: "exact")).to eq(2)
    end

    it "returns nil when no duplicate exists" do
      table = build_parsed_table(["Alice", "alice@example.com"])

      expect(DocTables.duplicate_row_index(table, column_index: 0, value: "Charlie", match: "exact")).to be_nil
    end

    it "skips the header row" do
      table = { rows: [{ row_index: 0, cells: [{ text: "Name\n", column_index: 0 }] }] }

      expect(DocTables.duplicate_row_index(table, column_index: 0, value: "Name", match: "exact")).to be_nil
    end
  end

  # ── placeholder_row_index ────────────────────────────────────────

  describe ".placeholder_row_index" do
    it "detects a placeholder row with angle-bracket tokens" do
      table = build_parsed_table_with_placeholder

      expect(DocTables.placeholder_row_index(table)).to eq(1)
    end

    it "detects a placeholder row with empty cells" do
      table = {
        rows: [
          { row_index: 0, cells: header_row_cells },
          { row_index: 1, cells: [
            { text: "\n", column_index: 0 },
            { text: "\n", column_index: 1 },
            { text: "\n", column_index: 2 }
          ] }
        ]
      }

      expect(DocTables.placeholder_row_index(table)).to eq(1)
    end

    it "returns nil when there are multiple data rows" do
      table = build_parsed_table(["A", "B", "C"], ["D", "E", "F"])

      expect(DocTables.placeholder_row_index(table)).to be_nil
    end

    it "returns nil when the single data row has content" do
      table = build_parsed_table(["Real content", "More", "Stuff"])

      expect(DocTables.placeholder_row_index(table)).to be_nil
    end
  end

  # ── reusable_row_index ────────────────────────────────────────────

  describe ".reusable_row_index" do
    it "detects a placeholder row in a blank template" do
      table = build_parsed_table_with_placeholder

      expect(DocTables.reusable_row_index(table)).to eq(1)
    end

    it "detects a trailing empty row after existing data" do
      table = build_parsed_table(["01/01/2026", "A", "B"], ["", "", ""])

      expect(DocTables.reusable_row_index(table)).to eq(2)
    end

    it "returns nil when last row has content" do
      table = build_parsed_table(["01/01/2026", "A", "B"])

      expect(DocTables.reusable_row_index(table)).to be_nil
    end

    it "returns nil when table has no data rows" do
      table = { rows: [{ row_index: 0, cells: header_row_cells }] }

      expect(DocTables.reusable_row_index(table)).to be_nil
    end
  end

  # ── parse content indices ────────────────────────────────────────

  describe ".parse content indices" do
    it "sets text_start_index one past the cell boundary" do
      table = structural_table(
        [logbook_header_row],
        start_index: 2, end_index: 43
      )
      tab = tab_with_content("t.0", table)
      doc = document_with_tabs(tab)

      result = DocTables.parse(doc)
      cell = result[0][:tables][0][:rows][0][:cells][0]

      expect(cell[:text_start_index]).to eq(cell[:start_index] + 1)
      expect(cell[:text_end_index]).to eq(cell[:end_index])
    end
  end

  # ── dated_paragraphs ─────────────────────────────────────────────

  describe ".dated_paragraphs" do
    it "finds paragraphs outside the table with date patterns" do
      tab = {
        tab_id: "t.0", tables: [],
        outside_paragraphs: [
          { text: "Titel\n", start_index: 0, end_index: 6 },
          { text: "11/09/2026 Begeleiding\n", start_index: 100, end_index: 123 }
        ]
      }

      result = DocTables.dated_paragraphs(tab)

      expect(result.length).to eq(1)
      expect(result[0][:text]).to include("11/09/2026")
    end

    it "returns empty for nil or no matches" do
      expect(DocTables.dated_paragraphs(nil)).to eq([])
      expect(DocTables.dated_paragraphs({ outside_paragraphs: [] })).to eq([])
    end
  end

  # ── verify ───────────────────────────────────────────────────────

  describe ".verify" do
    it "confirms a successful append with date dedup" do
      before_table = build_parsed_table(["01/01/2026", "A", "B"])
      after_table = build_parsed_table(["01/01/2026", "A", "B"], ["11/09/2026", "New", "Todo"])
      before_tab = { tab_id: "t.0", tables: [before_table], outside_paragraphs: [] }
      after_tab = { tab_id: "t.0", tables: [after_table], outside_paragraphs: [] }
      dedup = { column_index: 0, match: "date" }

      result = DocTables.verify(before_tab, after_tab, before_table, after_table,
                                ["11/09/2026", "New", "Todo"], dedup: dedup)

      expect(result[:verification][:row_found]).to be(true)
      expect(result[:verification][:previous_rows_intact]).to be(true)
      expect(result[:verification][:text_added_outside_table]).to be(false)
      expect(result[:warnings]).to be_empty
    end

    it "confirms a successful append with exact dedup" do
      before_table = build_parsed_table(["Alice", "alice@example.com"])
      after_table = build_parsed_table(["Alice", "alice@example.com"], ["Bob", "bob@example.com"])
      before_tab = { tab_id: "t.0", tables: [before_table], outside_paragraphs: [] }
      after_tab = { tab_id: "t.0", tables: [after_table], outside_paragraphs: [] }
      dedup = { column_index: 0, match: "exact" }

      result = DocTables.verify(before_tab, after_tab, before_table, after_table,
                                ["Bob", "bob@example.com"], dedup: dedup)

      expect(result[:verification][:row_found]).to be(true)
      expect(result[:verification][:previous_rows_intact]).to be(true)
    end

    it "confirms a successful append without dedup (matches all cells)" do
      before_table = build_parsed_table
      after_table = build_parsed_table(["X", "Y", "Z"])
      before_tab = { tab_id: "t.0", tables: [before_table], outside_paragraphs: [] }
      after_tab = { tab_id: "t.0", tables: [after_table], outside_paragraphs: [] }

      result = DocTables.verify(before_tab, after_tab, before_table, after_table, ["X", "Y", "Z"])

      expect(result[:verification][:row_found]).to be(true)
    end

    it "detects missing new row" do
      table = build_parsed_table(["01/01/2026", "A", "B"])
      tab = { tab_id: "t.0", tables: [table], outside_paragraphs: [] }
      dedup = { column_index: 0, match: "date" }

      result = DocTables.verify(tab, tab, table, table, ["11/09/2026", "New", "Todo"], dedup: dedup)

      expect(result[:verification][:row_found]).to be(false)
    end

    it "detects modified existing rows" do
      before_table = build_parsed_table(["01/01/2026", "Original", "B"])
      after_table = build_parsed_table(["01/01/2026", "Changed", "B"], ["11/09/2026", "New", "Todo"])
      before_tab = { tab_id: "t.0", tables: [before_table], outside_paragraphs: [] }
      after_tab = { tab_id: "t.0", tables: [after_table], outside_paragraphs: [] }

      result = DocTables.verify(before_tab, after_tab, before_table, after_table,
                                ["11/09/2026", "New", "Todo"], dedup: { column_index: 0, match: "date" })

      expect(result[:verification][:previous_rows_intact]).to be(false)
    end

    it "warns on duplicate dedup values in the result" do
      after_table = build_parsed_table(["Alice", "a@x.com"], ["Alice", "b@x.com"])
      before_table = build_parsed_table
      before_tab = { tab_id: "t.0", tables: [before_table], outside_paragraphs: [] }
      after_tab = { tab_id: "t.0", tables: [after_table], outside_paragraphs: [] }

      result = DocTables.verify(before_tab, after_tab, before_table, after_table,
                                ["Alice", "b@x.com"], dedup: { column_index: 0, match: "exact" })

      expect(result[:warnings]).to include(match(/appears 2 times/))
    end

    it "skips placeholder rows in the before comparison" do
      before_table = build_parsed_table_with_placeholder
      after_table = build_parsed_table(["11/09/2026", "Content", "Todo"])
      before_tab = { tab_id: "t.0", tables: [before_table], outside_paragraphs: [] }
      after_tab = { tab_id: "t.0", tables: [after_table], outside_paragraphs: [] }

      result = DocTables.verify(before_tab, after_tab, before_table, after_table,
                                ["11/09/2026", "Content", "Todo"], dedup: { column_index: 0, match: "date" })

      expect(result[:verification][:previous_rows_intact]).to be(true)
    end
  end

  # ── Shared helpers ───────────────────────────────────────────────

  private

  def header_row_cells
    [
      { text: "Datum\n", column_index: 0 },
      { text: "Inhoud van het contact\n", column_index: 1 },
      { text: "To do\n", column_index: 2 }
    ]
  end

  def build_parsed_table(*data_rows)
    cols = data_rows.first&.length || 3
    rows = [{ row_index: 0, cells: header_row_cells.first(cols) }]
    data_rows.each_with_index do |values, idx|
      rows << {
        row_index: idx + 1,
        cells: values.each_with_index.map do |v, col|
          { text: "#{v}\n", column_index: col, start_index: 0, end_index: 0,
            text_start_index: 1, text_end_index: 0 }
        end
      }
    end
    { start_index: 2, end_index: 200, rows: rows, columns: cols }
  end

  def build_parsed_table_with_placeholder
    {
      start_index: 2, end_index: 100, columns: 3,
      rows: [
        { row_index: 0, cells: header_row_cells },
        { row_index: 1, cells: [
          { text: "<datum>\n", column_index: 0, start_index: 43, end_index: 52,
            text_start_index: 44, text_end_index: 52 },
          { text: "<inhoud>\n", column_index: 1, start_index: 53, end_index: 63,
            text_start_index: 54, text_end_index: 63 },
          { text: "<to do>\n", column_index: 2, start_index: 64, end_index: 73,
            text_start_index: 65, text_end_index: 73 }
        ] }
      ]
    }
  end
end
