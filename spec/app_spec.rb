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
  end
end
