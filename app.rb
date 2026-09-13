require "sinatra/base"
require "json"

require_relative "lib/service"
require_relative "lib/google_workspace"
require_relative "lib/tools/concerns/google_auth"
require_relative "lib/tools/google_drive_tools"

class DokService < Sinatra::Base
  TOOLS = {
    "google_list_files" => Tools::ListFiles,
    "google_search_files" => Tools::SearchFiles,
    "google_read_file" => Tools::ReadFile,
    "google_read_document" => Tools::ReadDocument,
    "google_create_folder" => Tools::CreateFolder,
    "google_create_document" => Tools::CreateDocument,
    "google_create_document_from_template" => Tools::CreateDocumentFromTemplate,
    "google_update_document" => Tools::UpdateDocument,
    "google_move_file" => Tools::MoveFile,
    "google_delete_file" => Tools::DeleteFile,
    "google_export_file" => Tools::ExportFile
  }.freeze

  set :show_exceptions, false
  set :host_authorization, { permitted_hosts: [] }

  get "/health" do
    "OK"
  end

  post "/call" do
    content_type :json
    body = request.body.read
    data = JSON.parse(body)
    tool_name = data["tool"]
    handler = TOOLS[tool_name]

    return { error: "Unknown tool: #{tool_name}" }.to_json unless handler

    result = handler.call(
      params: data.fetch("params", {}),
      context: data.fetch("context", {})
    )
    result.to_json
  rescue JSON::ParserError => e
    status 400
    { error: "Invalid JSON: #{e.message}" }.to_json
  rescue StandardError => e
    $stderr.puts "[ERROR] #{tool_name}: #{e.class}: #{e.message}"
    $stderr.puts e.backtrace.first(5).join("\n")
    { error: "Internal error: #{e.message}" }.to_json
  end

  run! if app_file == $0
end
