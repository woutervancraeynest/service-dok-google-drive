require "spec_helper"
require_relative "support/fake_docs_model"

RSpec.describe "Cell-targeted table operations" do
  DATE_PH = "Klik of tik om een datum in te voeren.".freeze
  TEXT_PH = "Klik of tik om tekst in te voeren.".freeze

  let(:drive_files) do
    {
      "root" => drive_file("root", GoogleWorkspace::FOLDER_MIME_TYPE, []),
      "doc" => drive_file("doc", GoogleWorkspace::DOCUMENT_MIME_TYPE, ["root"]),
      "elsewhere" => drive_file("elsewhere", GoogleWorkspace::FOLDER_MIME_TYPE, []),
      "outside" => drive_file("outside", GoogleWorkspace::DOCUMENT_MIME_TYPE, ["elsewhere"])
    }
  end
  let(:drive) do
    files = drive_files
    Class.new do
      define_method(:get_file) do |id, **|
        files.fetch(id) { raise Google::Apis::ClientError.new("Not found", status_code: 404) }
      end
    end.new
  end
  let(:blocks) { ed_blocks }
  let(:docs) { FakeDocsModel.new(blocks) }
  let(:client) do
    GoogleWorkspace::Client.new(configuration: { "root_folder_id" => "root" }, oauth_tokens: {},
                                drive_service: drive, docs_service: docs)
  end

  def drive_file(id, mime_type, parents)
    OpenStruct.new(id: id, name: "File #{id}", mime_type: mime_type, parents: parents, trashed: false,
                   shortcut_details: nil)
  end

  def ed_blocks
    [
      { paragraph: "Leersteunplan ED", heading: true },
      { paragraph: "Agenda", heading: true },
      { table: [
        ["", "Datum", "Aanwezigen"],
        ["Opstartgesprek", DATE_PH, ""],
        ["Evaluatie 1", DATE_PH, ""],
        ["Evaluatie 2", DATE_PH, ""]
      ] },
      { paragraph: "Doelstellingen", heading: true },
      { table: [["Doelstellingen"], [""], ["Aanpak"], [TEXT_PH]] }
    ]
  end

  def update(**overrides)
    client.update_table_cell(
      file_id: "doc",
      value: "09/10/2026",
      required_revision_id: docs.revision_id,
      table_selector: { "section_heading" => "Agenda" },
      row_selector: { "cell_text" => "Opstartgesprek" },
      column_selector: { "header_text" => "Datum" },
      **overrides
    )
  end

  def agenda_snapshot
    (0...docs.table_rows(0)).map { |r| (0..2).map { |c| docs.cell_text(0, r, c) } }
  end

  describe "#inspect_document_tables" do
    it "returns tables with stable ids, labels and cell states but no Docs indices" do
      result = client.inspect_document_tables(file_id: "doc")

      expect(result[:revision_id]).to eq("rev-1")
      expect(result[:table_count]).to eq(2)
      agenda = result[:tables][0]
      expect(agenda).to include(table_id: "t.0/0", label: "Agenda", section_heading: "Agenda",
                                row_count: 4, column_count: 3)
      expect(agenda[:rows][1][:cells].map { |c| [c[:cell_id], c[:text], c[:state]] }).to eq([
        ["t.0/0/1/0", "Opstartgesprek", "filled"],
        ["t.0/0/1/1", DATE_PH, "placeholder"],
        ["t.0/0/1/2", "", "empty"]
      ])
      expect(result.to_s).not_to include("start_index")
      expect(result.to_s).not_to include("end_index")
    end

    it "filters tables with a table selector" do
      result = client.inspect_document_tables(file_id: "doc",
                                              table_selector: { "contains_text" => "Aanpak" })

      expect(result[:tables].map { |t| t[:table_id] }).to eq(["t.0/1"])
    end

    it "honours extra placeholders" do
      docs.set_cell(0, 1, 2, "(namen)")
      result = client.inspect_document_tables(file_id: "doc", placeholders: ["(namen)"])

      expect(result[:tables][0][:rows][1][:cells][2][:state]).to eq("placeholder")
    end
  end

  describe "#update_table_cell — ED agenda scenario" do
    it "dry-runs without writing and reports the selected cell" do
      result = update(dry_run: true)

      expect(result).to include(status: "would_update", dry_run: true, written: false,
                                table: "Agenda", row: "Opstartgesprek", column: "Datum",
                                row_index: 1, column_index: 1, cell_id: "t.0/0/1/1",
                                old_value: DATE_PH, new_value: "09/10/2026", cell_state: "placeholder")
      expect(docs.batch_requests).to be_empty
    end

    it "fills the date cell and then the attendees cell, touching nothing else" do
      before = agenda_snapshot

      date = update
      expect(date).to include(status: "updated", written: true, old_value: DATE_PH, new_value: "09/10/2026")
      expect(date[:revision_id]).to eq(docs.revision_id)
      expect(date[:verification][:ok]).to be(true)

      attendees = update(value: "Chantal, Sofie (ouder), Ilse (CLB)",
                         required_revision_id: date[:revision_id],
                         column_selector: { "header_text" => "Aanwezigen" })
      expect(attendees).to include(status: "updated", column: "Aanwezigen", old_value: "")

      after = agenda_snapshot
      expect(after.length).to eq(before.length)
      expect(after[1]).to eq(["Opstartgesprek", "09/10/2026", "Chantal, Sofie (ouder), Ilse (CLB)"])
      expect(after.values_at(0, 2, 3)).to eq(before.values_at(0, 2, 3))
      expect(docs.cell_text(1, 3, 0)).to eq(TEXT_PH)
    end

    it "sends only a deleteContentRange and insertText for the target cell" do
      update
      requests = docs.batch_requests.first.requests

      expect(requests.map { |r| r.delete_content_range ? :delete : :insert }).to eq(%i[delete insert])
      expect(requests.none?(&:insert_table_row)).to be(true)
      expect(docs.batch_requests.first.write_control.required_revision_id).to eq("rev-1")
    end

    it "is idempotent when the cell already holds the value" do
      first = update
      second = update(required_revision_id: first[:revision_id])

      expect(second).to include(status: "unchanged", written: false)
      expect(docs.batch_requests.length).to eq(1)
    end
  end

  describe "#update_table_cell — refusals write nothing" do
    it "rejects a missing revision" do
      result = update(required_revision_id: "")

      expect(result[:status]).to eq("invalid_request")
      expect(docs.batch_requests).to be_empty
    end

    it "rejects a stale revision and returns the current one" do
      result = update(required_revision_id: "rev-0")

      expect(result).to include(status: "revision_conflict", written: false, revision_id: "rev-1")
      expect(docs.batch_requests).to be_empty
    end

    it "reports table_not_found with available tables" do
      result = update(table_selector: { "section_heading" => "Verslag" })

      expect(result[:status]).to eq("table_not_found")
      expect(result[:available_tables].map { |t| t[:label] }).to eq(%w[Agenda Doelstellingen])
      expect(docs.batch_requests).to be_empty
    end

    it "reports row_not_found for an unknown row and never adds a row" do
      result = update(row_selector: { "cell_text" => "Slotgesprek" })

      expect(result[:status]).to eq("row_not_found")
      expect(docs.table_rows(0)).to eq(4)
      expect(docs.batch_requests).to be_empty
    end

    it "reports column_not_found for an unknown column" do
      result = update(column_selector: { "header_text" => "Locatie" })

      expect(result[:status]).to eq("column_not_found")
      expect(docs.batch_requests).to be_empty
    end

    it "reports column_not_found for an out-of-range index" do
      result = update(column_selector: { "index" => 5 })

      expect(result[:status]).to eq("column_not_found")
    end

    context "with a duplicated row label" do
      let(:blocks) do
        b = ed_blocks
        b[2][:table] << ["Opstartgesprek", DATE_PH, ""]
        b
      end

      it "returns ambiguous_match with candidates" do
        result = update

        expect(result[:status]).to eq("ambiguous_match")
        expect(result[:candidates].map { |c| c[:cell_id] }).to eq(["t.0/0/1/1", "t.0/0/4/1"])
        expect(docs.batch_requests).to be_empty
      end
    end

    it "refuses to overwrite meaningful content without replace_existing" do
      docs.set_cell(0, 1, 1, "01/10/2026")
      result = update

      expect(result).to include(status: "cell_not_empty", old_value: "01/10/2026", written: false)
      expect(docs.batch_requests).to be_empty
    end

    it "overwrites meaningful content with replace_existing" do
      docs.set_cell(0, 1, 1, "01/10/2026")
      result = update(replace_existing: true)

      expect(result).to include(status: "updated", old_value: "01/10/2026")
      expect(docs.cell_text(0, 1, 1)).to eq("09/10/2026")
    end

    it "refuses to write into the row label column" do
      result = update(column_selector: { "index" => 0 })

      expect(result[:status]).to eq("invalid_selector")
    end

    it "rejects mixing cell_selector with row/column selectors" do
      result = update(cell_selector: { "cell_id" => "t.0/0/1/1" })

      expect(result[:status]).to eq("invalid_selector")
    end

    it "rejects an empty value" do
      expect(update(value: "  ")[:status]).to eq("invalid_request")
    end

    it "enforces the project folder scope" do
      expect { client.update_table_cell(file_id: "outside", value: "x", required_revision_id: "rev-1") }
        .to raise_error(GoogleWorkspace::ScopeError)
    end

    context "with a date chip in the target cell" do
      let(:blocks) do
        b = ed_blocks
        b[2][:table][1][1] = { text: "", rich: true }
        b
      end

      it "treats the chip as meaningful content" do
        expect(update[:status]).to eq("cell_not_empty")
      end
    end

    context "with open suggestions in the target cell" do
      let(:blocks) do
        b = ed_blocks
        b[2][:table][1][1] = { text: "01/10/2026", suggested: true }
        b
      end

      it "refuses even with replace_existing" do
        result = update(replace_existing: true)

        expect(result).to include(status: "unsupported_cell_content", written: false)
        expect(result[:message]).to include("suggestions")
        expect(docs.batch_requests).to be_empty
      end

      it "flags the cell during inspection" do
        cell = client.inspect_document_tables(file_id: "doc")[:tables][0][:rows][1][:cells][1]

        expect(cell).to include(state: "filled", has_suggestions: true)
      end
    end

    context "with a nested table in the target cell" do
      let(:blocks) do
        b = ed_blocks
        b[2][:table][1][1] = { text: "", nested: true }
        b
      end

      it "refuses even with replace_existing" do
        expect(update(replace_existing: true)[:status]).to eq("unsupported_cell_content")
        expect(docs.batch_requests).to be_empty
      end
    end
  end

  describe "#update_table_cell — selectors" do
    it "targets a cell by cell_id from inspection" do
      inspection = client.inspect_document_tables(file_id: "doc")
      cell_id = inspection[:tables][0][:rows][2][:cells][2][:cell_id]

      result = client.update_table_cell(file_id: "doc", value: "Chantal", cell_selector: { "cell_id" => cell_id },
                                        required_revision_id: inspection[:revision_id])

      expect(result).to include(status: "updated", row: "Evaluatie 1")
      expect(docs.cell_text(0, 2, 2)).to eq("Chantal")
    end

    it "fills a one-column table via anchor text and relation" do
      result = client.update_table_cell(
        file_id: "doc", value: "Leest vlot een korte tekst.", required_revision_id: "rev-1",
        table_selector: { "section_heading" => "Doelstellingen" },
        cell_selector: { "anchor_text" => "Doelstellingen", "relation" => "below" }
      )

      expect(result).to include(status: "updated", row_index: 1, column_index: 0)
      expect(docs.cell_text(1, 1, 0)).to eq("Leest vlot een korte tekst.")
      expect(docs.cell_text(1, 0, 0)).to eq("Doelstellingen")
    end

    it "replaces a placeholder in a one-column table via 'next'" do
      result = client.update_table_cell(file_id: "doc", value: "Voorleessoftware", required_revision_id: "rev-1",
                                        cell_selector: { "anchor_text" => "aanpak:" })

      expect(result).to include(status: "updated", old_value: TEXT_PH)
      expect(docs.cell_text(1, 3, 0)).to eq("Voorleessoftware")
    end

    it "reports cell_not_found when the anchor has no related cell" do
      result = client.update_table_cell(file_id: "doc", value: "x", required_revision_id: "rev-1",
                                        cell_selector: { "anchor_text" => "Aanwezigen", "relation" => "right" })

      expect(result[:status]).to eq("cell_not_found")
    end

    it "matches row labels case- and whitespace-insensitively" do
      result = update(row_selector: { "cell_text" => " OPSTARTGESPREK\u00A0" })

      expect(result[:status]).to eq("updated")
    end

    it "requires a table_selector when selecting a row by index" do
      result = update(table_selector: nil, row_selector: { "row_index" => 1 })

      expect(result[:status]).to eq("invalid_selector")
    end

    context "with two identical agenda tables under different headings" do
      let(:blocks) do
        b = ed_blocks
        b.insert(3, { paragraph: "Agenda schooljaar 2", heading: true })
        b.insert(4, Marshal.load(Marshal.dump(b[2])))
        b
      end

      it "is ambiguous without a table selector" do
        expect(update(table_selector: nil)[:status]).to eq("ambiguous_match")
      end

      it "resolves with the section heading" do
        result = update(table_selector: { "section_heading" => "Agenda schooljaar 2" })

        expect(result).to include(status: "updated", table_id: "t.0/1")
        expect(docs.cell_text(1, 1, 1)).to eq("09/10/2026")
        expect(docs.cell_text(0, 1, 1)).to eq(DATE_PH)
      end
    end

    context "with a title row above the header row" do
      let(:blocks) do
        [{ table: [["Agenda", "", ""], ["", "Datum", "Aanwezigen"], ["Opstartgesprek", "", ""]] }]
      end

      it "uses the nearest header row and the first cell as table label" do
        result = update

        expect(result).to include(status: "updated", table: "Agenda", column_index: 1)
        expect(docs.cell_text(0, 2, 1)).to eq("09/10/2026")
      end
    end
  end

  describe "#update_table_cell — index calculation" do
    context "with Unicode text before and inside the table" do
      let(:blocks) do
        [
          { paragraph: "Leersteun 🎒 für Zoë", heading: true },
          { paragraph: "Agenda", heading: true },
          { table: [
            ["", "Datum", "Aanwezigen"],
            ["Kennismaking 👋🏽", "😀 ok", "Zoë"],
            ["Opstartgesprek", DATE_PH, ""],
            ["Évaluatie", "", ""]
          ] }
        ]
      end

      it "computes UTF-16 indices correctly and writes Unicode values verbatim" do
        result = update(value: "9 oktober 2026 — 👩‍🏫")

        expect(result[:status]).to eq("updated")
        expect(docs.cell_text(0, 2, 1)).to eq("9 oktober 2026 — 👩‍🏫")
        expect(docs.cell_text(0, 1, 1)).to eq("😀 ok")
        expect(docs.cell_text(0, 2, 0)).to eq("Opstartgesprek")
      end

      it "matches accented labels" do
        result = update(row_selector: { "cell_text" => "évaluatie" }, value: "Jürgen")

        expect(result[:status]).to eq("updated")
        expect(docs.cell_text(0, 3, 1)).to eq("Jürgen")
      end
    end

    it "replaces a multi-paragraph cell completely" do
      docs.set_cell(0, 1, 2, "Regel 1\nRegel 2")
      result = update(value: "Nieuw", column_selector: { "header_text" => "Aanwezigen" }, replace_existing: true)

      expect(result[:status]).to eq("updated")
      expect(docs.cell_text(0, 1, 2)).to eq("Nieuw")
    end

    it "writes multi-line values into one cell" do
      result = update(value: "Chantal\nSofie", column_selector: { "header_text" => "Aanwezigen" })

      expect(result[:status]).to eq("updated")
      expect(docs.cell_text(0, 1, 2)).to eq("Chantal\nSofie")
      expect(docs.cell_text(0, 2, 2)).to eq("")
    end
  end

  describe "#update_table_cell — concurrency and verification" do
    it "reports revision_conflict when the document changes just before the write" do
      docs.concurrent_edit_before_write! { |d| d.set_cell(1, 1, 0, "Menselijke bewerking") }
      result = update

      expect(result).to include(status: "revision_conflict", written: false)
      expect(docs.cell_text(0, 1, 1)).to eq(DATE_PH)
      expect(result[:revision_id]).to eq(docs.revision_id)
    end

    it "reports updated when the write landed but the response was lost" do
      docs.raise_after_apply!(Google::Apis::ServerError.new("Backend error", status_code: 503))
      result = update

      expect(result).to include(status: "updated", written: true)
      expect(docs.batch_requests.length).to eq(1)
    end

    it "reports write_failed when the write was rejected without document changes" do
      docs.concurrent_edit_before_write! { raise Google::Apis::ClientError.new("Bad request", status_code: 400) }
      result = update

      expect(result).to include(status: "write_failed", written: false)
    end

    it "reports verification_failed with written: true when the re-read after a successful write fails" do
      docs.fail_reads_after_write!(Google::Apis::ServerError.new("Backend error", status_code: 503))
      allow(client).to receive(:sleep)
      result = update

      expect(result).to include(status: "verification_failed", written: true, revision_id: nil)
      expect(result[:message]).to include("could not be re-read")
    end

    it "reports written: unknown when both the write response and the re-read fail" do
      docs.raise_after_apply!(Google::Apis::ServerError.new("Backend error", status_code: 503))
      docs.fail_reads_after_write!(Google::Apis::ClientError.new("Forbidden", status_code: 403))
      result = update

      expect(result).to include(status: "verification_failed", written: "unknown")
    end

    it "reports verification_failed with written: true when the cell does not hold the value" do
      docs.skip_apply!
      result = update

      expect(result).to include(status: "verification_failed", written: true)
      expect(result[:verification][:checks][:target_has_value]).to be(false)
    end
  end
end
