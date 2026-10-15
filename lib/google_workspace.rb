require "base64"
require "googleauth"
require "google/apis/drive_v3"
require "google/apis/docs_v1"
require "stringio"
require "time"
require "uri"
require_relative "doc_tables"
require_relative "doc_table_cells"

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
  MAX_APPEND_ATTEMPTS = 2
  MAX_INSPECT_TABLES = 50
  FILE_FIELDS = "id,name,mimeType,parents,trashed,webViewLink,modifiedTime,size,shortcutDetails(targetId,targetMimeType),driveId".freeze

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  class ScopeError < Error; end
  class ApiError < Error; end
  class RevisionConflictError < Error; end

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

    # ── Table operations ──────────────────────────────────────────────

    def append_table_row(file_id:, header_cells:, cells:, dedup: nil,
                         use_placeholder_row: true, required_revision_id: nil, dry_run: false)
      file = resolve_file_in_scope!(file_id)
      unless file.mime_type == DOCUMENT_MIME_TYPE
        raise ConfigurationError, "Only Google Docs documents support table operations."
      end

      # 1. Read the full structural document
      doc0 = get_structured_document(file.id)
      rev0 = doc0.revision_id
      parsed0 = DocTables.parse(doc0)

      # 2. Revision guard — the agent's last-known revision must match
      if !required_revision_id.to_s.strip.empty? && required_revision_id.to_s.strip != rev0
        match = DocTables.find_table(parsed0, header_cells)
        if match && dedup_match?(match[:table], dedup, cells)
          return append_result(status: "duplicate", file: file, revision_id: rev0, cells: cells, dedup: dedup)
        end
        return append_result(status: "revision_conflict", file: file, revision_id: rev0, cells: cells, dedup: dedup)
      end

      # 3. Find the target table by header cells
      table_match = DocTables.find_table(parsed0, header_cells)
      unless table_match
        return append_result(status: "table_not_found", file: file, revision_id: rev0, cells: cells, dedup: dedup)
      end
      tab_id = table_match[:tab_id]
      table0 = table_match[:table]

      # 4. Duplicate check
      if dedup_match?(table0, dedup, cells)
        return append_result(status: "duplicate", file: file, revision_id: rev0, cells: cells, dedup: dedup)
      end

      # 5. Determine path: reuse existing empty row or insert new one
      reuse_idx = use_placeholder_row ? DocTables.reusable_row_index(table0) : nil
      target_row_index = reuse_idx || table0[:rows].length

      # 6. Dry run — report what would happen, no writes
      if dry_run
        return append_result(
          status: "inserted", file: file, revision_id: rev0, cells: cells, dedup: dedup,
          table_row_index: target_row_index, dry_run: true
        )
      end

      values = cells.map(&:to_s)

      if reuse_idx
        # ── Fill existing empty/placeholder row ──────────────────────
        row = table0[:rows][reuse_idx]
        if row[:cells].length < values.length
          return append_result(status: "malformed_table", file: file, revision_id: rev0, cells: cells, dedup: dedup,
                               warnings: ["Placeholder row has #{row[:cells].length} cells, expected #{values.length}."])
        end

        requests = build_cell_fill_requests(tab_id, row[:cells], values)
        batch = build_guarded_batch(requests, rev0)
        begin
          guarded_batch_update(file.id, batch)
        rescue RevisionConflictError
          return append_result(status: "revision_conflict", file: file, revision_id: rev0, cells: cells, dedup: dedup)
        end
      else
        # ── Insert new row ───────────────────────────────────────────
        last_row_index = table0[:rows].length - 1
        rev = rev0
        current_table = table0
        attempts = 0

        loop do
          insert_req = build_insert_row_request(tab_id, current_table[:start_index], last_row_index)
          batch = build_guarded_batch([insert_req], rev)
          begin
            guarded_batch_update(file.id, batch)
            break
          rescue RevisionConflictError
            attempts += 1
            if attempts >= MAX_APPEND_ATTEMPTS
              return append_result(status: "revision_conflict", file: file, revision_id: rev, cells: cells, dedup: dedup)
            end
            doc_retry = get_structured_document(file.id)
            rev = doc_retry.revision_id
            parsed_retry = DocTables.parse(doc_retry)
            retry_match = DocTables.find_table(parsed_retry, header_cells)
            unless retry_match
              return append_result(status: "table_not_found", file: file, revision_id: rev, cells: cells, dedup: dedup)
            end
            if dedup_match?(retry_match[:table], dedup, cells)
              return append_result(status: "duplicate", file: file, revision_id: rev, cells: cells, dedup: dedup)
            end
            current_table = retry_match[:table]
            last_row_index = current_table[:rows].length - 1
          end
        end

        # Re-read after row insert — indices have changed
        doc1 = get_structured_document(file.id)
        rev1 = doc1.revision_id
        parsed1 = DocTables.parse(doc1)
        match1 = DocTables.find_table(parsed1, header_cells)
        unless match1
          return append_result(status: "partial_failure", file: file, revision_id: rev1, cells: cells, dedup: dedup,
                               warnings: ["Row inserted but table not found for cell fill."])
        end
        new_row = match1[:table][:rows].last
        if new_row[:cells].length < values.length
          return append_result(status: "partial_failure", file: file, revision_id: rev1, cells: cells, dedup: dedup,
                               warnings: ["New row has #{new_row[:cells].length} cells, expected #{values.length}."])
        end

        # Fill cells
        fill_reqs = build_cell_fill_requests(tab_id, new_row[:cells], values, clear: false)
        fill_batch = build_guarded_batch(fill_reqs, rev1)
        begin
          guarded_batch_update(file.id, fill_batch)
        rescue RevisionConflictError, ApiError => e
          return append_result(status: "partial_failure", file: file, revision_id: rev1, cells: cells, dedup: dedup,
                               warnings: ["Row inserted but cell fill failed: #{e.message}"])
        end
      end

      # 7. Verify the final state
      doc_final = get_structured_document(file.id)
      rev_final = doc_final.revision_id
      parsed_final = DocTables.parse(doc_final)
      match_final = DocTables.find_table(parsed_final, header_cells)

      unless match_final
        return append_result(status: "partial_failure", file: file, revision_id: rev_final, cells: cells, dedup: dedup,
                             warnings: ["Write succeeded but table not found during verification."])
      end

      tab_before = parsed0.find { |t| t[:tab_id] == tab_id }
      tab_after = parsed_final.find { |t| t[:tab_id] == tab_id }
      v = DocTables.verify(tab_before, tab_after, table0, match_final[:table], cells, dedup: dedup)

      append_result(
        status: "inserted", file: file, revision_id: rev_final, cells: cells, dedup: dedup,
        table_row_index: target_row_index, verification: v[:verification], warnings: v[:warnings]
      )
    end

    def analyze_document_tables(file_id:, header_cells: nil)
      file = resolve_file_in_scope!(file_id)
      unless file.mime_type == DOCUMENT_MIME_TYPE
        raise ConfigurationError, "Only Google Docs documents can be analyzed."
      end

      doc = get_structured_document(file.id)
      parsed = DocTables.parse(doc)

      analysis = {
        id: file.id,
        name: file.name,
        revision_id: doc.revision_id,
        tabs: parsed.map { |tab| serialize_tab_analysis(tab) }
      }

      if header_cells.is_a?(Array) && header_cells.any?
        match = DocTables.find_table(parsed, header_cells)
        if match
          analysis[:matched_table] = {
            tab_id: match[:tab_id],
            start_index: match[:table][:start_index],
            rows: serialize_table_rows(match[:table])
          }
        else
          analysis[:matched_table] = nil
          analysis[:warnings] = ["No table found matching the given header cells."]
        end
      end

      analysis
    end

    # ── Cell-targeted table operations ───────────────────────────────

    def inspect_document_tables(file_id:, table_selector: nil, placeholders: [])
      file = resolve_file_in_scope!(file_id)
      unless file.mime_type == DOCUMENT_MIME_TYPE
        raise ConfigurationError, "Only Google Docs documents can be inspected."
      end

      doc = get_structured_document(file.id)
      tables = DocTableCells.inspect_tables(
        DocTables.parse(doc), table_selector: table_selector, placeholders: Array(placeholders)
      )

      {
        id: file.id,
        name: file.name,
        revision_id: doc.revision_id,
        table_count: tables.length,
        tables: tables.first(MAX_INSPECT_TABLES),
        truncated: tables.length > MAX_INSPECT_TABLES
      }
    end

    # Fills exactly one existing table cell. Every non-"updated" status
    # means nothing was written, unless the result says written: true.
    def update_table_cell(file_id:, value:, required_revision_id:, table_selector: nil, row_selector: nil,
                          column_selector: nil, cell_selector: nil, replace_existing: false,
                          dry_run: false, placeholders: [])
      file = resolve_file_in_scope!(file_id)
      unless file.mime_type == DOCUMENT_MIME_TYPE
        raise ConfigurationError, "Only Google Docs documents support table operations."
      end

      required_revision_id = required_revision_id.to_s.strip
      if required_revision_id.empty?
        return cell_result("invalid_request", file, nil,
                           message: "required_revision_id is required. Read or inspect the document first.")
      end
      unless value.is_a?(String) && !DocTableCells.clean_value(value).empty?
        return cell_result("invalid_request", file, nil, message: "value must be a non-empty string.")
      end
      value = value.gsub("\r\n", "\n")

      doc0 = get_structured_document(file.id)
      rev0 = doc0.revision_id
      if required_revision_id != rev0
        return cell_result("revision_conflict", file, rev0,
                           message: "The document changed since it was read. Inspect it again.")
      end

      parsed0 = DocTables.parse(doc0)
      resolution = DocTableCells.resolve(
        parsed0,
        table_selector: table_selector, row_selector: row_selector,
        column_selector: column_selector, cell_selector: cell_selector
      )
      unless resolution[:status] == "resolved"
        return cell_result(resolution[:status], file, rev0, **resolution.except(:status))
      end

      target = resolution[:target]
      cell = target[:cell]
      old_value = DocTableCells.clean_value(cell[:text])
      state = DocTableCells.cell_state(cell, placeholders: Array(placeholders))
      details = DocTableCells.describe_target(target).except(:current_value)
                             .merge(old_value: old_value, new_value: value, cell_state: state)

      if cell[:nested_table]
        return cell_result("unsupported_cell_content", file, rev0, **details,
                           message: "The target cell contains a nested table.")
      end
      if cell[:suggestions]
        return cell_result("unsupported_cell_content", file, rev0, **details,
                           message: "The target cell contains open suggestions. Accept or reject them first.")
      end
      if old_value == DocTableCells.clean_value(value) && cell[:rich_elements].to_i.zero?
        return cell_result("unchanged", file, rev0, **details, message: "The cell already contains this value.")
      end
      if state == "filled" && !replace_existing
        return cell_result("cell_not_empty", file, rev0, **details,
                           message: "The target cell already has content. Pass replace_existing: true to overwrite.")
      end
      return cell_result("would_update", file, rev0, **details, dry_run: true) if dry_run

      requests = build_cell_fill_requests(target[:tab_id], [cell], [value], clear: true)
      write_error = attempt_batch_update(file.id, build_guarded_batch(requests, rev0))

      begin
        doc1 = get_structured_document(file.id)
      rescue ApiError, AuthenticationError => e
        return cell_result("verification_failed", file, nil, written: write_error.nil? ? true : "unknown", **details,
                           message: "The document could not be re-read after the write (#{e.class.name.split('::').last}). " \
                                    "Inspect the cell before retrying.")
      end
      rev1 = doc1.revision_id
      verification = DocTableCells.verify_update(parsed0, DocTables.parse(doc1), target, value)

      if write_error.nil?
        status = verification[:ok] ? "updated" : "verification_failed"
        return cell_result(status, file, rev1, written: true, **details, verification: verification)
      end

      if rev1 == rev0
        return cell_result("write_failed", file, rev1, **details,
                           message: "Google Docs rejected the update (#{api_error_code(write_error)}).")
      end
      if verification[:ok]
        return cell_result("updated", file, rev1, written: true, **details, verification: verification)
      end

      current = DocTableCells.locate(DocTables.parse(doc1), target[:tab_id], target[:table][:table_index],
                                     target[:row_index], target[:column_index])
      if current && DocTableCells.clean_value(current[:text]) == old_value
        return cell_result("revision_conflict", file, rev1, **details,
                           message: "The document changed concurrently; the update was not applied.")
      end

      cell_result("verification_failed", file, rev1, written: "unknown", **details, verification: verification,
                  message: "The document changed concurrently; inspect the cell before retrying.")
    end

    private

    # Single attempt without retries: a retried write could apply twice or
    # be misreported. The caller re-reads the document to learn the outcome.
    def attempt_batch_update(file_id, batch_request)
      @docs.batch_update_document(file_id, batch_request)
      nil
    rescue Google::Apis::AuthorizationError
      raise AuthenticationError
    rescue Google::Apis::Error => e
      e
    end

    def api_error_code(error)
      error.respond_to?(:status_code) && error.status_code ? error.status_code : error.class.name.split("::").last
    end

    def cell_result(status, file, revision_id, written: false, **extra)
      { status: status, file_id: file.id, written: written, revision_id: revision_id }.merge(extra.compact)
    end

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

    # ── Structured document access ──────────────────────────────────

    def get_structured_document(file_id)
      api_call { @docs.get_document(file_id, include_tabs_content: true) }
    end

    # ── Guarded writes (detect revision conflicts) ───────────────────

    def guarded_batch_update(file_id, batch_request)
      retries = 0
      begin
        @docs.batch_update_document(file_id, batch_request)
      rescue Google::Apis::RateLimitError, Google::Apis::ServerError => e
        raise ApiError, "Google API is temporarily unavailable (#{e.status_code})." if retries >= MAX_RETRIES
        retries += 1
        sleep(retries)
        retry
      end
    rescue Google::Apis::AuthorizationError
      raise AuthenticationError
    rescue Google::Apis::ClientError => e
      raise RevisionConflictError, "Document was modified concurrently." if e.status_code == 409
      raise ApiError, "Google API request failed (#{e.status_code})."
    end

    # ── Docs API request builders ────────────────────────────────────

    def build_guarded_batch(requests, revision_id)
      Google::Apis::DocsV1::BatchUpdateDocumentRequest.new(
        requests: requests,
        write_control: Google::Apis::DocsV1::WriteControl.new(
          required_revision_id: revision_id
        )
      )
    end

    def build_insert_row_request(tab_id, table_start_index, row_index)
      Google::Apis::DocsV1::Request.new(
        insert_table_row: Google::Apis::DocsV1::InsertTableRowRequest.new(
          table_cell_location: Google::Apis::DocsV1::TableCellLocation.new(
            table_start_location: Google::Apis::DocsV1::Location.new(
              index: table_start_index,
              tab_id: tab_id
            ),
            row_index: row_index,
            column_index: 0
          ),
          insert_below: true
        )
      )
    end

    # Build cell-fill requests in right-to-left order (highest index first).
    # Uses text_start_index / text_end_index (content paragraph positions)
    # rather than cell structural boundaries to avoid invalid-index errors.
    # When +clear+ is true, existing cell content is deleted first.
    def build_cell_fill_requests(tab_id, cells, values, clear: true)
      requests = []
      cells.first(values.length).zip(values).reverse_each do |cell, value|
        text_start = cell[:text_start_index]
        text_end = cell[:text_end_index]

        if clear && text_end - 1 > text_start
          requests << Google::Apis::DocsV1::Request.new(
            delete_content_range: Google::Apis::DocsV1::DeleteContentRangeRequest.new(
              range: Google::Apis::DocsV1::Range.new(
                start_index: text_start,
                end_index: text_end - 1,
                tab_id: tab_id
              )
            )
          )
        end
        requests << Google::Apis::DocsV1::Request.new(
          insert_text: Google::Apis::DocsV1::InsertTextRequest.new(
            location: Google::Apis::DocsV1::Location.new(
              index: text_start,
              tab_id: tab_id
            ),
            text: value.to_s
          )
        )
      end
      requests
    end

    # ── Result builders ──────────────────────────────────────────────

    def append_result(status:, file:, revision_id:, cells:, dedup: nil, table_row_index: nil,
                      verification: nil, warnings: [], dry_run: false)
      result = {
        status: status,
        file_id: file.id,
        revision_id: revision_id
      }
      if dedup && dedup[:match] && dedup[:match] != "none"
        result[:dedup_value] = cells[dedup[:column_index]]
      end
      result[:table_row_index] = table_row_index if table_row_index
      result[:verification] = verification if verification
      result[:warnings] = warnings
      result[:dry_run] = true if dry_run
      result
    end

    def dedup_match?(table, dedup, cells)
      return false unless dedup && dedup[:match] && dedup[:match] != "none"

      col = dedup[:column_index]
      value = cells[col]
      DocTables.duplicate_row_index(table, column_index: col, value: value, match: dedup[:match])
    end

    # ── Analyze helpers ──────────────────────────────────────────────

    def serialize_tab_analysis(tab)
      {
        tab_id: tab[:tab_id],
        tables: tab[:tables].map do |t|
          { start_index: t[:start_index], rows: t[:rows].length, columns: t[:columns] }
        end,
        outside_paragraphs: tab[:outside_paragraphs].map do |p|
          { text: p[:text].strip[0..200], start_index: p[:start_index], end_index: p[:end_index] }
        end,
        detected_dates: DocTables.dated_paragraphs(tab).map do |o|
          { text: o[:text].strip[0..200], start_index: o[:start_index] }
        end
      }
    end

    def serialize_table_rows(table)
      table[:rows].map do |row|
        {
          row_index: row[:row_index],
          cells: row[:cells].map { |c| { column_index: c[:column_index], text: c[:text].strip[0..200] } }
        }
      end
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
