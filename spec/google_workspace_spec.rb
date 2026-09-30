require "spec_helper"

RSpec.describe GoogleWorkspace::Client do
  let(:root) { drive_file("root", "Project", GoogleWorkspace::FOLDER_MIME_TYPE) }
  let(:subfolder) { drive_file("subfolder", "Drafts", GoogleWorkspace::FOLDER_MIME_TYPE, parents: ["root"]) }
  let(:document) { drive_file("document", "Plan", GoogleWorkspace::DOCUMENT_MIME_TYPE, parents: ["subfolder"]) }
  let(:elsewhere) { drive_file("elsewhere", "Other", GoogleWorkspace::FOLDER_MIME_TYPE) }
  let(:outside) { drive_file("outside", "Private", GoogleWorkspace::DOCUMENT_MIME_TYPE, parents: ["elsewhere"]) }
  let(:drive) { FakeDrive.new([root, subfolder, document, elsewhere, outside]) }
  let(:docs) { FakeDocs.new }
  let(:client) do
    described_class.new(
      configuration: { "root_folder_id" => "root" },
      oauth_tokens: {},
      drive_service: drive,
      docs_service: docs
    )
  end

  describe "folder scope" do
    it "accepts a Google Drive folder URL" do
      linked_client = described_class.new(
        configuration: { "root_folder_id" => "https://drive.google.com/drive/u/0/folders/root?usp=sharing" },
        oauth_tokens: {},
        drive_service: drive,
        docs_service: docs
      )

      expect(linked_client.root_folder_id).to eq("root")
    end

    it "lists files from the root folder" do
      result = client.list_files

      expect(result[:files].map { |file| file[:id] }).to eq(["subfolder"])
    end

    it "allows resources in descendant folders" do
      expect(client.read_document(file_id: "document")[:id]).to eq("document")
    end

    it "rejects resources outside the configured subtree" do
      expect { client.read_document(file_id: "outside") }
        .to raise_error(GoogleWorkspace::ScopeError, /outside/)
    end

    it "does not allow deleting the root folder" do
      expect { client.delete_file(file_id: "root") }
        .to raise_error(GoogleWorkspace::ScopeError, /root folder cannot be deleted/)
    end
  end

  describe "document operations" do
    it "reads document text and revision" do
      result = client.read_document(file_id: "document")

      expect(result[:text]).to eq("Hello\n")
      expect(result[:revision_id]).to eq("revision-1")
    end

    it "reads a non-Google-Docs file as bounded base64 content" do
      text_file = drive_file("text-file", "Notes.txt", "text/plain", parents: ["root"])
      text_file.define_singleton_method(:size) { 4 }
      drive.add_file(text_file)
      drive.downloads["text-file"] = "note"

      result = client.read_file(file_id: "text-file")

      expect(result[:content_base64]).to eq(Base64.strict_encode64("note"))
    end

    it "updates a document with revision control" do
      result = client.update_document(
        file_id: "document",
        requests: [{ "insertText" => { "location" => { "index" => 1 }, "text" => "New" } }],
        required_revision_id: "revision-1"
      )

      expect(result[:revision_id]).to eq("revision-2")
      expect(docs.last_request.write_control.required_revision_id).to eq("revision-1")
    end

    it "creates a folder in the configured subtree" do
      result = client.create_folder(name: "New folder")

      expect(result[:name]).to eq("New folder")
      expect(result[:parents]).to eq(["root"])
    end

    it "moves a file within the configured subtree" do
      result = client.move_file(file_id: "document", parent_id: "root")

      expect(result[:parents]).to eq(["root"])
    end

    it "deletes a descendant file" do
      result = client.delete_file(file_id: "document")

      expect(result[:deleted]).to be(true)
    end

    it "copies a template into the project folder" do
      result = client.create_document_from_template(
        template_file_id: "document",
        name: "New from template"
      )

      expect(result[:id]).to start_with("copy-")
      expect(result[:parents]).to eq(["root"])
    end

    it "exports a document" do
      drive.exports["document"] = "%PDF-fake"

      result = client.export_file(
        file_id: "document",
        mime_type: "application/pdf"
      )

      expect(result[:content_base64]).to eq(Base64.strict_encode64("%PDF-fake"))
    end
  end

  describe "search" do
    it "finds files by name across subfolders" do
      result = client.search_files(query: "Plan")

      expect(result[:files].map { |f| f[:id] }).to include("document")
    end

    it "includes matching folders in results" do
      result = client.search_files(query: "Drafts")

      expect(result[:files].map { |f| f[:id] }).to include("subfolder")
    end

    it "respects the folder visit budget" do
      result = client.search_files(query: "nonexistent")

      expect(result[:folders_searched]).to be <= GoogleWorkspace::MAX_SEARCH_FOLDERS
    end

    it "rejects a blank query" do
      expect { client.search_files(query: "") }
        .to raise_error(GoogleWorkspace::ConfigurationError, /blank/)
    end
  end

  describe "error handling" do
    it "rejects missing root folder configuration" do
      expect {
        described_class.new(configuration: {}, oauth_tokens: {}, drive_service: drive, docs_service: docs)
      }.to raise_error(GoogleWorkspace::ConfigurationError, /root folder/)
    end

    it "rejects empty file names" do
      expect { client.create_folder(name: "") }
        .to raise_error(GoogleWorkspace::ConfigurationError, /non-empty name/)
    end

    it "rejects names longer than 255 characters" do
      expect { client.create_folder(name: "x" * 256) }
        .to raise_error(GoogleWorkspace::ConfigurationError, /255 characters/)
    end

    it "rejects reading a folder as file content" do
      expect { client.read_file(file_id: "subfolder") }
        .to raise_error(GoogleWorkspace::ConfigurationError, /google_list_files/)
    end

    it "rejects non-downloadable Workspace types" do
      sheet = drive_file("sheet", "Budget", "application/vnd.google-apps.spreadsheet", parents: ["root"])
      drive.add_file(sheet)

      expect { client.read_file(file_id: "sheet") }
        .to raise_error(GoogleWorkspace::ConfigurationError, /google_export_file/)
    end

    it "rejects files exceeding the size limit before downloading" do
      big_file = drive_file("big", "dump.bin", "application/octet-stream", parents: ["root"])
      big_file.define_singleton_method(:size) { 10 * 1024 * 1024 }
      drive.add_file(big_file)

      expect { client.read_file(file_id: "big") }
        .to raise_error(GoogleWorkspace::ConfigurationError, /too large/)
    end

    it "does not allow moving the root folder" do
      expect { client.move_file(file_id: "root", parent_id: "subfolder") }
        .to raise_error(GoogleWorkspace::ScopeError, /root folder cannot be moved/)
    end
  end

  describe "shortcut handling" do
    it "filters out shortcuts pointing outside the subtree" do
      shortcut_outside = drive_file("sc-out", "Shortcut", GoogleWorkspace::DOCUMENT_MIME_TYPE, parents: ["root"])
      shortcut_outside.shortcut_details = OpenStruct.new(target_id: "outside", target_mime_type: GoogleWorkspace::DOCUMENT_MIME_TYPE)
      drive.add_file(shortcut_outside)

      result = client.list_files

      expect(result[:files].map { |f| f[:id] }).not_to include("sc-out")
    end

    it "keeps shortcuts pointing inside the subtree" do
      shortcut_inside = drive_file("sc-in", "Shortcut", GoogleWorkspace::DOCUMENT_MIME_TYPE, parents: ["root"])
      shortcut_inside.shortcut_details = OpenStruct.new(target_id: "document", target_mime_type: GoogleWorkspace::DOCUMENT_MIME_TYPE)
      drive.add_file(shortcut_inside)

      result = client.list_files

      expect(result[:files].map { |f| f[:id] }).to include("sc-in")
    end
  end

  describe "URL parsing" do
    it "extracts folder ID from a plain /folders/ URL" do
      c = described_class.new(
        configuration: { "root_folder_id" => "https://drive.google.com/drive/folders/abc123" },
        oauth_tokens: {},
        drive_service: drive,
        docs_service: docs
      )
      expect(c.root_folder_id).to eq("abc123")
    end

    it "rejects non-Google URLs" do
      expect {
        described_class.new(
          configuration: { "root_folder_id" => "https://example.com/folders/abc" },
          oauth_tokens: {},
          drive_service: drive,
          docs_service: docs
        )
      }.to raise_error(GoogleWorkspace::ConfigurationError, /drive\.google\.com/)
    end

    it "rejects HTTP URLs" do
      expect {
        described_class.new(
          configuration: { "root_folder_id" => "http://drive.google.com/drive/folders/abc" },
          oauth_tokens: {},
          drive_service: drive,
          docs_service: docs
        )
      }.to raise_error(GoogleWorkspace::ConfigurationError)
    end
  end

  def drive_file(id, name, mime_type, parents: [])
    OpenStruct.new(
      id: id,
      name: name,
      mime_type: mime_type,
      parents: parents,
      trashed: false,
      modified_time: nil,
      size: nil,
      web_view_link: "https://drive.google.com/file/d/#{id}/view",
      shortcut_details: nil
    )
  end

  class FakeDrive
    attr_reader :downloads, :exports

    def initialize(files)
      @files = files.to_h { |file| [file.id, file] }
      @downloads = {}
      @exports = {}
    end

    def add_file(file)
      @files[file.id] = file
    end

    def get_file(id, download_dest: nil, **)
      file = @files.fetch(id)
      download_dest.write(@downloads.fetch(id, "")) if download_dest
      file
    end

    def list_files(q:, **)
      parent_id = q[/\A'([^']+)'/, 1]
      OpenStruct.new(files: @files.values.select { |file| file.parents.include?(parent_id) }, next_page_token: nil)
    end

    def create_file(file, **)
      created = OpenStruct.new(
        id: "created",
        name: file.name,
        mime_type: file.mime_type,
        parents: file.parents,
        trashed: false,
        modified_time: nil,
        size: nil,
        web_view_link: nil,
        shortcut_details: nil
      )
      @files[created.id] = created
      created
    end

    def copy_file(file_id, file, **)
      create_file(file, **{}).tap { |copy| copy.id = "copy-#{file_id}" }
    end

    def update_file(file_id, _file, add_parents:, **)
      file = @files.fetch(file_id)
      file.parents = [add_parents]
      file
    end

    def delete_file(file_id, **)
      @files.delete(file_id)
    end

    def export_file(file_id, _mime_type, download_dest:, **)
      download_dest.write(@exports.fetch(file_id, ""))
    end
  end

  class FakeDocs
    attr_reader :last_request

    def get_document(_id, **)
      paragraph = OpenStruct.new(
        elements: [OpenStruct.new(text_run: OpenStruct.new(content: "Hello\n"))]
      )
      OpenStruct.new(
        revision_id: "revision-1",
        body: OpenStruct.new(content: [OpenStruct.new(paragraph: paragraph)]),
        tabs: []
      )
    end

    def batch_update_document(_id, request)
      @last_request = request
      OpenStruct.new(
        write_control: OpenStruct.new(required_revision_id: "revision-2"),
        replies: []
      )
    end
  end

  # ── Table-aware fake Docs service ────────────────────────────────

  class FakeTableDocs
    attr_reader :batch_requests

    def initialize(snapshots)
      @snapshots = snapshots
      @read_count = 0
      @batch_requests = []
      @conflict_on_batch = nil
    end

    def get_document(_id, **)
      doc = @snapshots[[@read_count, @snapshots.length - 1].min]
      @read_count += 1
      doc
    end

    def batch_update_document(_id, request)
      if @conflict_on_batch == @batch_requests.length
        @batch_requests << request
        raise Google::Apis::ClientError.new("Conflict", status_code: 409)
      end
      @batch_requests << request
      OpenStruct.new(
        write_control: OpenStruct.new(required_revision_id: "revision-next"),
        replies: []
      )
    end

    def conflict_on_batch!(index)
      @conflict_on_batch = index
    end
  end

  # ── Document builders ─────────────────────────────────────────────

  def table_doc(revision_id:, tab_id: "t.0", headers: nil, data_rows: [], outside: [])
    headers ||= [
      { text: "Datum\n", start: 3, end: 10 },
      { text: "Inhoud van het contact\n", start: 11, end: 34 },
      { text: "To do\n", start: 35, end: 42 }
    ]
    columns = headers.length

    all_rows = [build_doc_row(headers)]
    base = headers.last[:end] + 1
    data_rows.each do |cells|
      row = cells.map do |text|
        cell = { text: "#{text}\n", start: base, end: base + text.length + 1 }
        base += text.length + 2
        cell
      end
      all_rows << build_doc_row(row)
    end

    table_element = OpenStruct.new(
      start_index: 2, end_index: base,
      table: OpenStruct.new(table_rows: all_rows, columns: columns),
      paragraph: nil
    )

    content = [table_element]
    outside.each do |para|
      s = para[:start] || base + 1
      content << OpenStruct.new(
        start_index: s, end_index: s + para[:text].length,
        paragraph: OpenStruct.new(elements: [OpenStruct.new(text_run: OpenStruct.new(content: para[:text]))]),
        table: nil
      )
    end

    tab = OpenStruct.new(
      tab_properties: OpenStruct.new(tab_id: tab_id),
      document_tab: OpenStruct.new(body: OpenStruct.new(content: content)),
      child_tabs: []
    )
    OpenStruct.new(tabs: [tab], body: nil, revision_id: revision_id)
  end

  def placeholder_doc(revision_id:, tab_id: "t.0")
    header = [
      { text: "Datum\n", start: 3, end: 10 },
      { text: "Inhoud van het contact\n", start: 11, end: 34 },
      { text: "To do\n", start: 35, end: 42 }
    ]
    placeholder = [
      { text: "<datum>\n", start: 43, end: 51 },
      { text: "<inhoud>\n", start: 52, end: 61 },
      { text: "<to do>\n", start: 62, end: 70 }
    ]

    table_element = OpenStruct.new(
      start_index: 2, end_index: 71,
      table: OpenStruct.new(table_rows: [build_doc_row(header), build_doc_row(placeholder)], columns: 3),
      paragraph: nil
    )

    tab = OpenStruct.new(
      tab_properties: OpenStruct.new(tab_id: tab_id),
      document_tab: OpenStruct.new(body: OpenStruct.new(content: [table_element])),
      child_tabs: []
    )
    OpenStruct.new(tabs: [tab], body: nil, revision_id: revision_id)
  end

  def build_doc_row(cells)
    OpenStruct.new(table_cells: cells.map { |c| build_doc_cell(c) })
  end

  def build_doc_cell(cell)
    # Realistic: content paragraph starts 1 past the cell boundary
    content_start = cell[:start] + 1
    OpenStruct.new(
      start_index: cell[:start], end_index: cell[:end],
      content: [OpenStruct.new(
        start_index: content_start, end_index: cell[:end],
        paragraph: OpenStruct.new(elements: [OpenStruct.new(text_run: OpenStruct.new(content: cell[:text]))]),
        table: nil
      )]
    )
  end

  LOGBOOK_HEADERS = ["Datum", "Inhoud van het contact", "To do"].freeze
  DATE_DEDUP = { column_index: 0, match: "date" }.freeze

  # ── append_table_row ─────────────────────────────────────────────

  describe "append_table_row" do
    it "fills a placeholder row in a blank template" do
      initial = placeholder_doc(revision_id: "rev-1")
      final = table_doc(revision_id: "rev-2", data_rows: [["11/09/2026", "Begeleiding SV", "- Actie"]])

      fake_docs = FakeTableDocs.new([initial, final])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Begeleiding SV", "- Actie"],
        dedup: DATE_DEDUP, required_revision_id: "rev-1"
      )

      expect(result[:status]).to eq("inserted")
      expect(result[:table_row_index]).to eq(1)
      expect(result[:verification][:row_found]).to be(true)
      expect(fake_docs.batch_requests.length).to eq(1)
    end

    it "uses text_start_index (not cell boundary) for insertText" do
      initial = placeholder_doc(revision_id: "rev-1")
      final = table_doc(revision_id: "rev-2", data_rows: [["11/09/2026", "Content", "Todo"]])

      fake_docs = FakeTableDocs.new([initial, final])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Content", "Todo"]
      )

      batch = fake_docs.batch_requests[0]
      batch.requests.select { |r| r.insert_text }.each do |req|
        # Content paragraph starts at cell boundary + 1; insertText must
        # target that position, never the cell's own start_index.
        expect(req.insert_text.location.index).to be > 2
        # Placeholder cells start at 43,52,62 — content at 44,53,63
        expect([44, 53, 63]).to include(req.insert_text.location.index)
      end
    end

    it "reuses a trailing empty row from a failed partial insert" do
      initial = table_doc(revision_id: "rev-1", data_rows: [["01/01/2026", "Existing", "Old"], ["", "", ""]])
      final = table_doc(revision_id: "rev-2", data_rows: [["01/01/2026", "Existing", "Old"], ["11/09/2026", "New", "Todo"]])

      fake_docs = FakeTableDocs.new([initial, final])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "New", "Todo"], dedup: DATE_DEDUP
      )

      expect(result[:status]).to eq("inserted")
      expect(result[:table_row_index]).to eq(2) # reused the empty row
      expect(fake_docs.batch_requests.length).to eq(1) # fill only, no insertTableRow
      expect(result[:verification][:previous_rows_intact]).to be(true)
    end

    it "inserts a new row in an existing table" do
      initial = table_doc(revision_id: "rev-1", data_rows: [["01/01/2026", "Existing", "Old"]])
      after_insert = table_doc(revision_id: "rev-2", data_rows: [["01/01/2026", "Existing", "Old"], ["", "", ""]])
      final = table_doc(revision_id: "rev-3", data_rows: [["01/01/2026", "Existing", "Old"], ["11/09/2026", "New", "Todo"]])

      fake_docs = FakeTableDocs.new([initial, after_insert, final])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "New", "Todo"], dedup: DATE_DEDUP, required_revision_id: "rev-1"
      )

      expect(result[:status]).to eq("inserted")
      expect(result[:table_row_index]).to eq(2)
      expect(result[:verification][:previous_rows_intact]).to be(true)
      expect(fake_docs.batch_requests.length).to eq(2)
    end

    it "returns duplicate with date dedup" do
      doc = table_doc(revision_id: "rev-1", data_rows: [["11/09/2026", "Existing", "Todo"]])
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Another", "More"], dedup: DATE_DEDUP, required_revision_id: "rev-1"
      )

      expect(result[:status]).to eq("duplicate")
      expect(result[:dedup_value]).to eq("11/09/2026")
      expect(fake_docs.batch_requests).to be_empty
    end

    it "returns duplicate with exact dedup on a two-column table" do
      headers = [
        { text: "Name\n", start: 3, end: 9 },
        { text: "Email\n", start: 10, end: 17 }
      ]
      doc = table_doc(revision_id: "rev-1", headers: headers, data_rows: [["Alice", "alice@x.com"]])
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: ["Name", "Email"],
        cells: ["Alice", "alice-new@x.com"],
        dedup: { column_index: 0, match: "exact" }
      )

      expect(result[:status]).to eq("duplicate")
      expect(result[:dedup_value]).to eq("Alice")
    end

    it "inserts without dedup when dedup is nil" do
      initial = table_doc(revision_id: "rev-1", data_rows: [["11/09/2026", "Existing", "Todo"]])
      after_insert = table_doc(revision_id: "rev-2", data_rows: [
        ["11/09/2026", "Existing", "Todo"], ["", "", ""]
      ])
      final = table_doc(revision_id: "rev-3", data_rows: [
        ["11/09/2026", "Existing", "Todo"], ["11/09/2026", "Second entry", "More"]
      ])

      fake_docs = FakeTableDocs.new([initial, after_insert, final])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Second entry", "More"]
      )

      expect(result[:status]).to eq("inserted")
      expect(result).not_to have_key(:dedup_value)
    end

    it "normalises dates for duplicate detection" do
      doc = table_doc(revision_id: "rev-1", data_rows: [["1/9/2026", "Existing", "Todo"]])
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["01/09/2026", "Entry", "Todo"], dedup: DATE_DEDUP
      )

      expect(result[:status]).to eq("duplicate")
    end

    it "returns table_not_found when headers do not match" do
      doc = table_doc(revision_id: "rev-1")
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: ["Wrong", "Headers"],
        cells: ["A", "B"]
      )

      expect(result[:status]).to eq("table_not_found")
    end

    it "returns revision_conflict when required_revision_id is stale" do
      doc = table_doc(revision_id: "rev-2")
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Content", "Todo"], dedup: DATE_DEDUP,
        required_revision_id: "rev-1"
      )

      expect(result[:status]).to eq("revision_conflict")
    end

    it "returns duplicate on stale revision when value was already added" do
      doc = table_doc(revision_id: "rev-2", data_rows: [["11/09/2026", "Already there", "Done"]])
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Content", "Todo"], dedup: DATE_DEDUP,
        required_revision_id: "rev-1"
      )

      expect(result[:status]).to eq("duplicate")
    end

    it "performs a dry run without writing" do
      doc = table_doc(revision_id: "rev-1", data_rows: [["01/01/2026", "Existing", "Todo"]])
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Content", "Todo"], dedup: DATE_DEDUP, dry_run: true
      )

      expect(result[:status]).to eq("inserted")
      expect(result[:dry_run]).to be(true)
      expect(result[:table_row_index]).to eq(2)
      expect(fake_docs.batch_requests).to be_empty
    end

    it "retries on revision conflict during row insert" do
      initial = table_doc(revision_id: "rev-1")
      after_conflict = table_doc(revision_id: "rev-2")
      after_insert = table_doc(revision_id: "rev-3", data_rows: [["", "", ""]])
      final = table_doc(revision_id: "rev-4", data_rows: [["11/09/2026", "Content", "Todo"]])

      fake_docs = FakeTableDocs.new([initial, after_conflict, after_insert, final])
      fake_docs.conflict_on_batch!(0)
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Content", "Todo"], dedup: DATE_DEDUP,
        required_revision_id: "rev-1"
      )

      expect(result[:status]).to eq("inserted")
      expect(fake_docs.batch_requests.length).to eq(3)
    end

    it "uses tabId in all Docs API requests" do
      initial = placeholder_doc(revision_id: "rev-1", tab_id: "t.custom")
      final = table_doc(revision_id: "rev-2", tab_id: "t.custom", data_rows: [["11/09/2026", "Content", "Todo"]])

      fake_docs = FakeTableDocs.new([initial, final])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Content", "Todo"]
      )

      fake_docs.batch_requests[0].requests.each do |req|
        expect(req.insert_text.location.tab_id).to eq("t.custom") if req.insert_text
        expect(req.delete_content_range.range.tab_id).to eq("t.custom") if req.delete_content_range
      end
    end

    it "never uses endOfSegmentLocation" do
      initial = placeholder_doc(revision_id: "rev-1")
      final = table_doc(revision_id: "rev-2", data_rows: [["11/09/2026", "Content", "Todo"]])

      fake_docs = FakeTableDocs.new([initial, final])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Content", "Todo"]
      )

      fake_docs.batch_requests.each do |batch|
        batch.requests.each do |req|
          next unless req.insert_text
          expect(req.insert_text.location.index).to be_a(Integer)
          expect(req.insert_text.end_of_segment_location).to be_nil
        end
      end
    end

    it "handles Dutch special characters" do
      initial = table_doc(revision_id: "rev-1")
      after_insert = table_doc(revision_id: "rev-2", data_rows: [["", "", ""]])
      final = table_doc(revision_id: "rev-3", data_rows: [
        ["11/09/2026", "Begeleiding met co\u00F6rdinatie", "- \u00C9\u00E9n actie"]
      ])

      fake_docs = FakeTableDocs.new([initial, after_insert, final])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.append_table_row(
        file_id: "document", header_cells: LOGBOOK_HEADERS,
        cells: ["11/09/2026", "Begeleiding met co\u00F6rdinatie", "- \u00C9\u00E9n actie"],
        dedup: DATE_DEDUP
      )

      expect(result[:status]).to eq("inserted")
      expect(result[:verification][:row_found]).to be(true)
    end
  end

  # ── analyze_document_tables ──────────────────────────────────────

  describe "analyze_document_tables" do
    it "returns table structure and outside paragraphs" do
      doc = table_doc(
        revision_id: "rev-1",
        data_rows: [["01/01/2026", "Entry", "Todo"]],
        outside: [{ text: "11/09/2026 Loose text\n", start: 300 }]
      )
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.analyze_document_tables(file_id: "document", header_cells: LOGBOOK_HEADERS)

      expect(result[:id]).to eq("document")
      expect(result[:matched_table]).not_to be_nil
      expect(result[:matched_table][:rows].length).to eq(2) # header + 1 data row
      expect(result[:tabs][0][:detected_dates].length).to eq(1)
    end

    it "reports no match when headers differ" do
      doc = table_doc(revision_id: "rev-1")
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.analyze_document_tables(file_id: "document", header_cells: ["Wrong"])

      expect(result[:matched_table]).to be_nil
      expect(result[:warnings]).to include(match(/No table found/))
    end

    it "works without header_cells" do
      doc = table_doc(revision_id: "rev-1", data_rows: [["01/01/2026", "Entry", "Todo"]])
      fake_docs = FakeTableDocs.new([doc])
      c = described_class.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                              drive_service: drive, docs_service: fake_docs)

      result = c.analyze_document_tables(file_id: "document")

      expect(result[:tabs][0][:tables].length).to eq(1)
      expect(result).not_to have_key(:matched_table)
    end
  end
end
