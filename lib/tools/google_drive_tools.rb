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
end
