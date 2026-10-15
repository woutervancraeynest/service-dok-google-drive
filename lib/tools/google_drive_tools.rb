module Tools
  class ListFiles
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.list_files(parent_id: params["parent_id"], page_size: params.fetch("page_size", 50))
      end
    end
  end

  class SearchFiles
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.search_files(
          query: params["query"],
          mime_type: params["mime_type"],
          max_results: params.fetch("max_results", 50)
        )
      end
    end
  end

  class ReadDocument
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) { |client| client.read_document(file_id: params["file_id"]) }
    end
  end

  class ReadFile
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) { |client| client.read_file(file_id: params["file_id"]) }
    end
  end

  class CreateFolder
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.create_folder(name: params["name"], parent_id: params["parent_id"])
      end
    end
  end

  class CreateDocument
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.create_document(
          name: params["name"],
          parent_id: params["parent_id"],
          initial_text: params["initial_text"]
        )
      end
    end
  end

  class CreateDocumentFromTemplate
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.create_document_from_template(
          template_file_id: params["template_file_id"],
          name: params["name"],
          parent_id: params["parent_id"]
        )
      end
    end
  end

  class UpdateDocument
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.update_document(
          file_id: params["file_id"],
          requests: params["requests"],
          required_revision_id: params["required_revision_id"]
        )
      end
    end
  end

  class MoveFile
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.move_file(file_id: params["file_id"], parent_id: params["parent_id"])
      end
    end
  end

  class DeleteFile
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) { |client| client.delete_file(file_id: params["file_id"]) }
    end
  end

  class ExportFile
    extend GoogleAuth

    DEFAULT_MIME_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.export_file(
          file_id: params["file_id"],
          mime_type: params.fetch("mime_type", DEFAULT_MIME_TYPE)
        )
      end
    end
  end

  class AppendTableRow
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        table_selector = params.fetch("table_selector", {})
        dedup_raw = params["dedup"]
        dedup = if dedup_raw.is_a?(Hash) && dedup_raw["match"] && dedup_raw["match"] != "none"
          { column_index: dedup_raw.fetch("column_index", 0).to_i, match: dedup_raw["match"] }
        end

        client.append_table_row(
          file_id: params["file_id"],
          header_cells: table_selector.fetch("header_cells", []),
          cells: params.fetch("cells", []),
          dedup: dedup,
          use_placeholder_row: params.fetch("use_placeholder_row", true),
          required_revision_id: params["required_revision_id"],
          dry_run: params.fetch("dry_run", false)
        )
      end
    end
  end

  class AnalyzeDocumentTables
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        table_selector = params["table_selector"]
        header_cells = table_selector&.fetch("header_cells", nil) if table_selector.is_a?(Hash)
        client.analyze_document_tables(
          file_id: params["file_id"],
          header_cells: header_cells
        )
      end
    end
  end

  class InspectDocumentTables
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.inspect_document_tables(
          file_id: params["file_id"],
          table_selector: params["table_selector"],
          placeholders: params.fetch("placeholders", [])
        )
      end
    end
  end

  class UpdateTableCell
    extend GoogleAuth

    def self.call(params:, context:)
      with_google_client(context) do |client|
        client.update_table_cell(
          file_id: params["file_id"],
          value: params["value"],
          required_revision_id: params["required_revision_id"],
          table_selector: params["table_selector"],
          row_selector: params["row_selector"],
          column_selector: params["column_selector"],
          cell_selector: params["cell_selector"],
          replace_existing: params.fetch("replace_existing", false) == true,
          dry_run: params.fetch("dry_run", false) == true,
          placeholders: params.fetch("placeholders", [])
        )
      end
    end
  end
end
