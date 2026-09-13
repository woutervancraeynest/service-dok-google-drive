require "base64"
require "googleauth"
require "google/apis/drive_v3"
require "google/apis/docs_v1"
require "stringio"
require "time"
require "uri"

module GoogleWorkspace
  # C1: drive.file only covers files the app created or user selected via Picker.
  # Since we manage an entire pre-existing folder tree, we need the full drive scope.
  DRIVE_SCOPE = "https://www.googleapis.com/auth/drive".freeze
  DOCS_SCOPE = "https://www.googleapis.com/auth/documents".freeze
  FOLDER_MIME_TYPE = "application/vnd.google-apps.folder".freeze
  DOCUMENT_MIME_TYPE = "application/vnd.google-apps.document".freeze
  WORKSPACE_MIME_PREFIX = "application/vnd.google-apps.".freeze
  MAX_PAGE_SIZE = 100
  MAX_SEARCH_RESULTS = 100
  MAX_UPDATE_REQUESTS = 100
  MAX_EXPORT_BYTES = 5 * 1024 * 1024
  MAX_SEARCH_FOLDERS = 50
  MAX_RETRIES = 2
  FILE_FIELDS = "id,name,mimeType,parents,trashed,webViewLink,modifiedTime,size,shortcutDetails(targetId,targetMimeType),driveId".freeze

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  class ScopeError < Error; end
  class ApiError < Error; end

  class Client
    attr_reader :root_folder_id

    def self.from_context(context)
      configuration = context.fetch("configuration", {})
      oauth_tokens = context.fetch("oauth_tokens", {})
      new(configuration:, oauth_tokens:)
    end

    def initialize(configuration:, oauth_tokens:, drive_service: nil, docs_service: nil)
      @configuration = stringify_keys(configuration)
      @oauth_tokens = stringify_keys(oauth_tokens)
      @root_folder_id = extract_folder_id(@configuration["root_folder_id"] || @configuration["root_folder_url"])
      raise ConfigurationError, "Configure a Google Drive root folder for this project." if @root_folder_id.empty?

      @drive = drive_service || build_drive_service
      @docs = docs_service || build_docs_service
      @scope_cache = {} # H1: cache within_root? results per Client instance
    end

    def root_folder
      folder = fetch_file(@root_folder_id)
      unless folder.mime_type == FOLDER_MIME_TYPE
        raise ScopeError, "Configured Google Drive resource is not a folder."
      end

      serialize_file(folder)
    end

    def list_files(parent_id: nil, page_size: 50)
      parent_id = parent_id.to_s.strip
      parent_id = @root_folder_id if parent_id.empty?
      assert_folder_in_scope!(parent_id)

      files = list_children(parent_id, page_size: page_size)
      files = files.select { |file| shortcut_in_scope?(file) }

      {
        root_folder_id: @root_folder_id,
        parent_id: parent_id,
        files: files.map { |file| serialize_file(file) },
        total: files.length
      }
    end

    def search_files(query:, mime_type: nil, max_results: 50)
      query = query.to_s.strip
      raise ConfigurationError, "Search query cannot be blank." if query.empty?

      max_results = [[max_results.to_i, 1].max, MAX_SEARCH_RESULTS].min
      matches = []
      folders = [@root_folder_id]
      visited_folders = {}
      query_lower = query.downcase

      # C4: cap folder traversal to prevent timeout on deep trees
      until folders.empty? || matches.length >= max_results || visited_folders.size >= MAX_SEARCH_FOLDERS
        folder_id = folders.shift
        next if visited_folders[folder_id]

        visited_folders[folder_id] = true
        list_children(folder_id, page_size: MAX_PAGE_SIZE).each do |file|
          next unless shortcut_in_scope?(file)

          name_matches = file.name.to_s.downcase.include?(query_lower)
          type_matches = mime_type.to_s.empty? || file.mime_type == mime_type

          if file.mime_type == FOLDER_MIME_TYPE
            folders << file.id
            # H2: include matching folders in results
            if name_matches && type_matches
              matches << serialize_file(file)
              break if matches.length >= max_results
            end
          elsif name_matches && type_matches
            matches << serialize_file(file)
            break if matches.length >= max_results
          end
        end
      end

      { query:, files: matches, total: matches.length, folders_searched: visited_folders.size }
    end

    # H6: internal method that accepts an already-validated file to avoid double scope check
    def read_document(file_id:)
      file = resolve_file_in_scope!(file_id)
      read_document_internal(file)
    end

    def read_file(file_id:)
      file = resolve_file_in_scope!(file_id)
      if file.mime_type == FOLDER_MIME_TYPE
        raise ConfigurationError, "Folders cannot be read as file content. Use google_list_files instead."
      end
      # H6: reuse already-validated file, don't re-resolve
      return read_document_internal(file) if file.mime_type == DOCUMENT_MIME_TYPE

      # H5: non-Docs Workspace types (Sheets, Slides, etc.) can't be downloaded directly
      if file.mime_type.to_s.start_with?(WORKSPACE_MIME_PREFIX)
        raise ConfigurationError,
          "#{file.name} is a Google Workspace file (#{file.mime_type}). " \
          "Use google_export_file to export it to a downloadable format (e.g. PDF)."
      end

      # C2: check known size before downloading to prevent OOM
      if file.size && file.size.to_i > MAX_EXPORT_BYTES
        raise ConfigurationError, "File is too large (#{file.size} bytes; maximum #{MAX_EXPORT_BYTES} bytes)."
      end

      content = StringIO.new
      api_call { @drive.get_file(file.id, download_dest: content, supports_all_drives: true) }
      bytes = content.string
      if bytes.bytesize > MAX_EXPORT_BYTES
        raise ConfigurationError, "File is too large to return through MCP (maximum #{MAX_EXPORT_BYTES} bytes)."
      end

      {
        id: file.id,
        name: file.name,
        mime_type: file.mime_type,
        byte_size: bytes.bytesize,
        content_base64: Base64.strict_encode64(bytes),
        web_view_link: file.web_view_link
      }
    end

    def create_folder(name:, parent_id: nil)
      name = required_name(name)
      parent_id = parent_id.to_s.strip
      parent_id = @root_folder_id if parent_id.empty?
      assert_folder_in_scope!(parent_id)

      file = Google::Apis::DriveV3::File.new(
        name: name,
        mime_type: FOLDER_MIME_TYPE,
        parents: [parent_id]
      )
      created = api_call do
        @drive.create_file(file, fields: FILE_FIELDS, supports_all_drives: true)
      end

      serialize_file(created)
    end

    def create_document(name:, parent_id: nil, initial_text: nil)
      name = required_name(name)
      parent_id = parent_id.to_s.strip
      parent_id = @root_folder_id if parent_id.empty?
      assert_folder_in_scope!(parent_id)

      file = Google::Apis::DriveV3::File.new(
        name: name,
        mime_type: DOCUMENT_MIME_TYPE,
        parents: [parent_id]
      )
      created = api_call do
        @drive.create_file(file, fields: FILE_FIELDS, supports_all_drives: true)
      end

      if !initial_text.to_s.empty?
        update_document(
          file_id: created.id,
          requests: [{ "insertText" => { "location" => { "index" => 1 }, "text" => initial_text.to_s } }]
        )
      end

      serialize_file(created)
    end

    def create_document_from_template(template_file_id:, name:, parent_id: nil)
      name = required_name(name)
      template = resolve_file_in_scope!(template_file_id)
      unless template.mime_type == DOCUMENT_MIME_TYPE
        raise ConfigurationError, "The template must be a Google Docs document."
      end

      parent_id = parent_id.to_s.strip
      parent_id = @root_folder_id if parent_id.empty?
      assert_folder_in_scope!(parent_id)

      copy = Google::Apis::DriveV3::File.new(name: name, parents: [parent_id])
      created = api_call do
        @drive.copy_file(template.id, copy, fields: FILE_FIELDS, supports_all_drives: true)
      end

      serialize_file(created)
    end

    def update_document(file_id:, requests:, required_revision_id: nil)
      file = resolve_file_in_scope!(file_id)
      unless file.mime_type == DOCUMENT_MIME_TYPE
        raise ConfigurationError, "Only Google Docs documents can be updated with this tool."
      end

      unless requests.is_a?(Array) && requests.any? && requests.length <= MAX_UPDATE_REQUESTS
        raise ConfigurationError, "Provide between 1 and #{MAX_UPDATE_REQUESTS} document update requests."
      end

      request_objects = requests.map do |request|
        unless request.is_a?(Hash) && request.keys.length == 1
          raise ConfigurationError, "Each document request must contain exactly one operation."
        end

        Google::Apis::DocsV1::Request.new(**symbolize_keys(request))
      end

      write_control = if required_revision_id.to_s.strip.empty?
        nil
      else
        Google::Apis::DocsV1::WriteControl.new(required_revision_id: required_revision_id.to_s)
      end

      body = Google::Apis::DocsV1::BatchUpdateDocumentRequest.new(
        requests: request_objects,
        write_control: write_control
      )
      result = api_call { @docs.batch_update_document(file.id, body) }

      {
        id: file.id,
        name: file.name,
        revision_id: result.write_control&.required_revision_id,
        replies: result.replies&.map(&:to_h) || []
      }
    end

    def move_file(file_id:, parent_id:)
      file = resolve_file_in_scope!(file_id)
      parent = assert_folder_in_scope!(parent_id)
      if file.id == @root_folder_id
        raise ScopeError, "The configured Google Drive root folder cannot be moved."
      end
      if file.mime_type == FOLDER_MIME_TYPE && folder_contains?(file.id, parent.id)
        raise ScopeError, "A folder cannot be moved into one of its descendants."
      end

      old_parents = Array(file.parents).reject { |id| id == parent.id }

      moved = api_call do
        @drive.update_file(
          file.id,
          Google::Apis::DriveV3::File.new,
          add_parents: parent.id,
          remove_parents: old_parents.join(","),
          fields: FILE_FIELDS,
          supports_all_drives: true
        )
      end

      serialize_file(moved)
    end

    def delete_file(file_id:)
      file = resolve_file_in_scope!(file_id)
      if file.id == @root_folder_id
        raise ScopeError, "The configured Google Drive root folder cannot be deleted."
      end

      api_call { @drive.delete_file(file.id, supports_all_drives: true) }
      { id: file.id, name: file.name, deleted: true }
    end

    def export_file(file_id:, mime_type:)
      file = resolve_file_in_scope!(file_id)
      exported = StringIO.new
      api_call { @drive.export_file(file.id, mime_type, download_dest: exported) }
      content = exported.string

      if content.bytesize > MAX_EXPORT_BYTES
        raise ConfigurationError, "Export is too large to return through MCP (maximum #{MAX_EXPORT_BYTES} bytes)."
      end

      {
        id: file.id,
        name: file.name,
        mime_type: mime_type,
        byte_size: content.bytesize,
        content_base64: Base64.strict_encode64(content)
      }
    end

    private

    def read_document_internal(file)
      unless file.mime_type == DOCUMENT_MIME_TYPE
        raise ConfigurationError, "Only Google Docs documents can be read with this tool."
      end

      document = api_call { @docs.get_document(file.id) }
      {
        id: file.id,
        name: file.name,
        mime_type: file.mime_type,
        revision_id: document.revision_id,
        text: document_text(document),
        web_view_link: file.web_view_link
      }
    end

    def build_drive_service
      service = Google::Apis::DriveV3::DriveService.new
      service.authorization = build_credentials
      service
    end

    def build_docs_service
      service = Google::Apis::DocsV1::DocsService.new
      service.authorization = build_credentials
      service
    end

    def build_credentials
      client_id = ENV["OAUTH_CLIENT_ID"].to_s.strip
      client_secret = ENV["OAUTH_CLIENT_SECRET"].to_s.strip
      refresh_token = @oauth_tokens["refresh_token"].to_s.strip
      if client_id.empty? || client_secret.empty? || refresh_token.empty?
        raise ConfigurationError, "Google OAuth is not configured. Connect the Google service first."
      end

      # C3: Signet accepts expires_at (Time), not expiry
      Google::Auth::UserRefreshCredentials.new(
        client_id: client_id,
        client_secret: client_secret,
        scope: [DRIVE_SCOPE, DOCS_SCOPE],
        refresh_token: refresh_token,
        access_token: @oauth_tokens["access_token"],
        expires_at: token_expiry
      )
    end

    def token_expiry
      value = @oauth_tokens["expires_at"]
      return if value.nil? || value.to_s.empty?

      value.is_a?(Numeric) ? Time.at(value) : Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def fetch_file(file_id)
      api_call do
        @drive.get_file(
          file_id.to_s,
          fields: FILE_FIELDS,
          supports_all_drives: true
        )
      end
    end

    def resolve_file_in_scope!(file_id)
      id = file_id.to_s.strip
      raise ConfigurationError, "A Google Drive file ID is required." if id.empty?

      file = fetch_file(id)
      unless within_root?(file)
        raise ScopeError, "Google Drive resource is outside the configured project folder."
      end

      file
    end

    def assert_folder_in_scope!(folder_id)
      folder = resolve_file_in_scope!(folder_id)
      unless folder.mime_type == FOLDER_MIME_TYPE
        raise ConfigurationError, "The selected Google Drive parent is not a folder."
      end

      folder
    end

    # H1: results are cached in @scope_cache for the lifetime of this Client instance
    def within_root?(file, visited = {})
      return true if file.id == @root_folder_id
      return @scope_cache[file.id] if @scope_cache.key?(file.id)
      return false if visited[file.id]
      return false if file.trashed

      visited[file.id] = true
      if file.shortcut_details&.target_id
        target = fetch_file(file.shortcut_details.target_id)
        unless within_root?(target, visited)
          @scope_cache[file.id] = false
          return false
        end
      end

      result = Array(file.parents).any? do |parent_id|
        next true if parent_id == @root_folder_id

        within_root?(fetch_file(parent_id), visited)
      end
      @scope_cache[file.id] = result
      result
    rescue Google::Apis::ClientError => e
      raise ApiError, "Google Drive lookup failed (#{e.status_code})."
    end

    def folder_contains?(ancestor_id, folder_id, visited = {})
      return true if ancestor_id == folder_id
      return false if visited[folder_id]

      visited[folder_id] = true
      folder = fetch_file(folder_id)
      Array(folder.parents).any? { |parent_id| folder_contains?(ancestor_id, parent_id, visited) }
    end

    def shortcut_in_scope?(file)
      return true unless file.shortcut_details&.target_id

      within_root?(fetch_file(file.shortcut_details.target_id))
    end

    def list_children(parent_id, page_size: MAX_PAGE_SIZE)
      page_size = [[page_size.to_i, 1].max, MAX_PAGE_SIZE].min
      files = []
      page_token = nil

      loop do
        response = api_call do
          @drive.list_files(
            q: "'#{parent_id}' in parents and trashed = false",
            spaces: "drive",
            page_size: page_size,
            page_token: page_token,
            order_by: "name",
            fields: "nextPageToken,files(#{FILE_FIELDS})",
            include_items_from_all_drives: true,
            supports_all_drives: true
          )
        end
        files.concat(response.files || [])
        page_token = response.next_page_token
        break if page_token.nil? || page_token.to_s.empty? || files.length >= MAX_SEARCH_RESULTS
      end

      files.first(MAX_SEARCH_RESULTS)
    end

    def required_name(name)
      value = name.to_s.strip
      raise ConfigurationError, "A non-empty name is required." if value.empty?
      raise ConfigurationError, "Names may not exceed 255 characters." if value.length > 255

      value
    end

    def serialize_file(file)
      {
        id: file.id,
        name: file.name,
        mime_type: file.mime_type,
        parents: file.parents || [],
        modified_time: file.modified_time,
        size: file.size,
        web_view_link: file.web_view_link,
        shortcut_target_id: file.shortcut_details&.target_id
      }.compact
    end

    def document_text(document)
      Array(document.body&.content).map { |element| element_text(element) }.join
    end

    def element_text(element)
      if (paragraph = element.paragraph)
        Array(paragraph.elements).filter_map { |item| item.text_run&.content }.join
      elsif (table = element.table)
        Array(table.table_rows).map do |row|
          Array(row.table_cells).map do |cell|
            Array(cell.content).map { |child| element_text(child) }.join
          end.join("\t")
        end.join("\n")
      else
        ""
      end
    end

    # H4: retry transient errors (429, 5xx) with exponential backoff
    def api_call
      retries = 0
      begin
        yield
      rescue Google::Apis::RateLimitError, Google::Apis::ServerError => e
        raise ApiError, "Google API is temporarily unavailable (#{e.status_code})." if retries >= MAX_RETRIES
        retries += 1
        sleep(retries)
        retry
      end
    rescue Google::Apis::AuthorizationError
      raise AuthenticationError
    rescue Google::Apis::ClientError => e
      raise ApiError, "Google API request failed (#{e.status_code})."
    end

    def extract_folder_id(value)
      value = value.to_s.strip
      return "" if value.empty?

      if value.match?(/\A[a-zA-Z0-9_-]+\z/)
        value
      else
        uri = URI.parse(value)
        unless uri.is_a?(URI::HTTPS) && uri.host == "drive.google.com"
          raise ConfigurationError, "Enter a Google Drive folder ID or a drive.google.com folder link."
        end

        path_parts = uri.path.split("/").reject(&:empty?)
        folder_index = path_parts.index("folders")
        folder_id = folder_index && path_parts[folder_index + 1]
        folder_id ||= URI.decode_www_form(uri.query.to_s).to_h["id"] if uri.query
        raise ConfigurationError, "Enter a Google Drive folder ID or a drive.google.com folder link." if folder_id.to_s.empty?

        folder_id
      end
    rescue URI::InvalidURIError
      raise ConfigurationError, "Enter a Google Drive folder ID or a drive.google.com folder link."
    end

    def self.stringify_keys(hash)
      hash.to_h.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    def stringify_keys(hash)
      self.class.stringify_keys(hash)
    end

    def symbolize_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key.to_s.gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase.to_sym] = symbolize_keys(child)
        end
      when Array
        value.map { |child| symbolize_keys(child) }
      else
        value
      end
    end
  end
end
