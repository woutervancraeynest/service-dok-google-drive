require "ostruct"
require "google/apis/docs_v1"

# In-memory Google Docs model for specs.
#
# Builds Docs API-shaped documents with realistic structural indices
# (UTF-16 code units, cell content one past the cell boundary) and applies
# deleteContentRange / insertText requests to the model, so index
# calculation and post-write verification are exercised for real.
#
# Blocks:
#   { paragraph: "Text", heading: true }
#   { table: [["Label", "Value"], ...] }
# A cell is a String (may contain "\n") or a Hash:
#   { text: "", rich: true }    # contains a date chip / smart chip
#   { text: "", nested: true }  # contains a nested table
#   { text: "x", suggested: true } # text is an open suggested deletion
class FakeDocsModel
  attr_reader :batch_requests, :revision_id

  def initialize(blocks, tab_id: "t.0", revision_id: "rev-1")
    @blocks = deep_copy(blocks)
    @tab_id = tab_id
    @revision_number = 1
    @revision_id = revision_id
    @batch_requests = []
    @before_batch = nil
    @after_batch = nil
    @skip_apply = false
  end

  # Simulates a human editing the document right before our write lands.
  def concurrent_edit_before_write!(&block)
    @before_batch = block
  end

  # Simulates a lost response: the write is applied but the call raises.
  def raise_after_apply!(error)
    @after_batch = error
  end

  # Makes every document read after the next write raise +error+.
  def fail_reads_after_write!(error)
    @fail_reads_after_write = error
  end

  # Simulates a write that reports success without changing the document.
  def skip_apply!
    @skip_apply = true
  end

  def cell_text(table_index, row_index, column_index)
    cell = tables[table_index][:table][row_index][column_index]
    cell.is_a?(Hash) ? cell[:text] : cell
  end

  def table_rows(table_index)
    tables[table_index][:table].length
  end

  def set_cell(table_index, row_index, column_index, text)
    tables[table_index][:table][row_index][column_index] = text
    bump_revision!
  end

  # ── Docs API surface ─────────────────────────────────────────────

  def get_document(_id, **)
    raise @fail_reads_after_write if @fail_reads_after_write && @batch_requests.any?

    build_document
  end

  def batch_update_document(_id, request)
    @batch_requests << request
    if @before_batch
      hook = @before_batch
      @before_batch = nil
      hook.call(self)
    end

    required = request.write_control&.required_revision_id
    if required && required != @revision_id
      raise Google::Apis::ClientError.new("Revision mismatch", status_code: 400)
    end

    unless @skip_apply
      Array(request.requests).each { |r| apply(r) }
      bump_revision!
    end

    if @after_batch
      error = @after_batch
      @after_batch = nil
      raise error
    end

    OpenStruct.new(write_control: OpenStruct.new(required_revision_id: @revision_id), replies: [])
  end

  private

  def tables
    @blocks.select { |b| b[:table] }
  end

  def bump_revision!
    @revision_number += 1
    @revision_id = "rev-#{@revision_number}"
  end

  def utf16_length(text)
    text.encode("UTF-16LE").bytesize / 2
  end

  # ── Document construction ───────────────────────────────────────

  def build_document
    @cell_ranges = []
    index = 1
    content = @blocks.map do |block|
      element, index = block[:table] ? build_table(block, index) : build_paragraph(block, index)
      element
    end

    tab = OpenStruct.new(
      tab_properties: OpenStruct.new(tab_id: @tab_id),
      document_tab: OpenStruct.new(body: OpenStruct.new(content: content)),
      child_tabs: []
    )
    OpenStruct.new(tabs: [tab], body: nil, revision_id: @revision_id)
  end

  def build_paragraph(block, index)
    text = "#{block[:paragraph]}\n"
    finish = index + utf16_length(text)
    style = OpenStruct.new(named_style_type: block[:heading] ? "HEADING_2" : "NORMAL_TEXT")
    element = OpenStruct.new(
      start_index: index, end_index: finish, table: nil,
      paragraph: OpenStruct.new(elements: [text_run(text)], paragraph_style: style)
    )
    [element, finish]
  end

  def build_table(block, index)
    table_start = index
    index += 1
    rows = block[:table].each_with_index.map do |cells, row_index|
      index += 1 # row marker
      table_cells = cells.each_with_index.map do |cell, column_index|
        table_index = tables.index { |t| t.equal?(block) }
        built, index = build_cell(cell, index, table_index, row_index, column_index)
        built
      end
      OpenStruct.new(table_cells: table_cells)
    end
    index += 1
    element = OpenStruct.new(
      start_index: table_start, end_index: index, paragraph: nil,
      table: OpenStruct.new(table_rows: rows, columns: block[:table].map(&:length).max)
    )
    [element, index]
  end

  def build_cell(cell, index, table_index, row_index, column_index)
    spec = cell.is_a?(Hash) ? cell : { text: cell }
    cell_start = index
    content_start = index + 1
    position = content_start
    lines = spec[:text].split("\n", -1)
    lines = [""] if lines.empty?
    elements = lines.map do |line|
      text = "#{line}\n"
      finish = position + utf16_length(text)
      items = [text_run(text)]
      items.first.text_run.suggested_deletion_ids = ["suggest.1"] if spec[:suggested]
      items.unshift(OpenStruct.new(date_element: OpenStruct.new(display_text: "1 okt 2026"))) if spec[:rich]
      paragraph = OpenStruct.new(
        start_index: position, end_index: finish, table: nil,
        paragraph: OpenStruct.new(elements: items, paragraph_style: nil)
      )
      position = finish
      paragraph
    end
    if spec[:nested]
      elements << OpenStruct.new(start_index: position, end_index: position + 5, paragraph: nil,
                                 table: OpenStruct.new(table_rows: [], columns: 0))
      position += 5
    end
    @cell_ranges << { table_index:, row_index:, column_index:, start: content_start, end: position }
    [OpenStruct.new(start_index: cell_start, end_index: position, content: elements), position]
  end

  def text_run(text)
    OpenStruct.new(text_run: OpenStruct.new(content: text))
  end

  # ── Request application ─────────────────────────────────────────

  def apply(request)
    build_document # refresh index map for the current model state
    if (delete = request.delete_content_range)
      range = delete.range
      cell = cell_at(range.start_index)
      if cell.nil? || range.end_index > cell[:end] - 1 || range.end_index <= range.start_index
        raise Google::Apis::ClientError.new("Invalid deletion range", status_code: 400)
      end
      edit_cell(cell) do |units|
        units.slice!(range.start_index - cell[:start], range.end_index - range.start_index)
        units
      end
    elsif (insert = request.insert_text)
      index = insert.location.index
      cell = cell_at(index)
      raise Google::Apis::ClientError.new("Invalid insert index", status_code: 400) unless cell

      edit_cell(cell) do |units|
        units.insert(index - cell[:start], *insert.text.encode("UTF-16LE").unpack("v*"))
      end
    else
      raise ArgumentError, "Unsupported request in fake: #{request.inspect}"
    end
  end

  def cell_at(index)
    @cell_ranges.find { |c| index >= c[:start] && index < c[:end] }
  end

  def edit_cell(range)
    rows = tables[range[:table_index]][:table]
    current = rows[range[:row_index]][range[:column_index]]
    text = current.is_a?(Hash) ? current[:text] : current
    units = text.encode("UTF-16LE").unpack("v*")
    units = yield(units)
    rows[range[:row_index]][range[:column_index]] = units.pack("v*").force_encoding("UTF-16LE").encode("UTF-8")
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
