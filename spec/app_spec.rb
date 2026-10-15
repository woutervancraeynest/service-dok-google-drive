require "spec_helper"

RSpec.describe DokService do
  describe "GET /health" do
    it "returns 200 OK" do
      get "/health"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("OK")
    end
  end

  describe "POST /call" do
    it "returns an error for an unknown tool" do
      call_tool("unknown_tool")

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["error"]).to include("Unknown tool")
    end

    it "returns an error for invalid JSON" do
      post "/call", "not json", { "CONTENT_TYPE" => "application/json" }

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]).to include("Invalid JSON")
    end

    it "dispatches a service tool" do
      client = instance_double(GoogleWorkspace::Client, list_files: { files: [], total: 0 })
      allow(GoogleWorkspace::Client).to receive(:from_context).and_return(client)

      call_tool("google_list_files", context: { "configuration" => { "root_folder_id" => "root" } })

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["total"]).to eq(0)
    end

    it "dispatches google_append_table_row" do
      client = instance_double(GoogleWorkspace::Client)
      allow(GoogleWorkspace::Client).to receive(:from_context).and_return(client)
      allow(client).to receive(:append_table_row).and_return({ status: "inserted", file_id: "doc1" })

      call_tool("google_append_table_row", params: {
        "file_id" => "doc1",
        "table_selector" => { "header_cells" => ["Datum", "Inhoud", "To do"] },
        "cells" => ["11/09/2026", "Content", "Todo"]
      })

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["status"]).to eq("inserted")
    end

    it "dispatches google_analyze_document_tables" do
      client = instance_double(GoogleWorkspace::Client)
      allow(GoogleWorkspace::Client).to receive(:from_context).and_return(client)
      allow(client).to receive(:analyze_document_tables).and_return({ id: "doc1", tabs: [] })

      call_tool("google_analyze_document_tables", params: { "file_id" => "doc1" })

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq("doc1")
    end

    it "dispatches google_inspect_document_tables" do
      client = instance_double(GoogleWorkspace::Client)
      allow(GoogleWorkspace::Client).to receive(:from_context).and_return(client)
      allow(client).to receive(:inspect_document_tables).and_return({ id: "doc1", tables: [] })

      call_tool("google_inspect_document_tables", params: { "file_id" => "doc1" })

      expect(client).to have_received(:inspect_document_tables)
        .with(file_id: "doc1", table_selector: nil, placeholders: [])
      expect(JSON.parse(last_response.body)["id"]).to eq("doc1")
    end

    it "dispatches google_update_table_cell with strict boolean flags" do
      client = instance_double(GoogleWorkspace::Client)
      allow(GoogleWorkspace::Client).to receive(:from_context).and_return(client)
      allow(client).to receive(:update_table_cell).and_return({ status: "would_update" })

      call_tool("google_update_table_cell", params: {
        "file_id" => "doc1",
        "value" => "09/10/2026",
        "required_revision_id" => "rev-1",
        "row_selector" => { "cell_text" => "Opstartgesprek" },
        "column_selector" => { "header_text" => "Datum" },
        "replace_existing" => "true",
        "dry_run" => true
      })

      expect(client).to have_received(:update_table_cell).with(hash_including(
        file_id: "doc1", value: "09/10/2026", required_revision_id: "rev-1",
        row_selector: { "cell_text" => "Opstartgesprek" }, replace_existing: false, dry_run: true
      ))
      expect(JSON.parse(last_response.body)["status"]).to eq("would_update")
    end

    it "lists every dispatched tool in the manifest" do
      manifest = JSON.parse(File.read(File.expand_path("../manifest.json", __dir__)))

      expect(manifest["tools"].map { |t| t["name"] }).to match_array(DokService::TOOLS.keys)
    end
  end
end
