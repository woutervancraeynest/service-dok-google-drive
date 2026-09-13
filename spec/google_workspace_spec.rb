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

    def get_document(_id)
      paragraph = OpenStruct.new(
        elements: [OpenStruct.new(text_run: OpenStruct.new(content: "Hello\n"))]
      )
      OpenStruct.new(
        revision_id: "revision-1",
        body: OpenStruct.new(content: [OpenStruct.new(paragraph: paragraph)])
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
end
