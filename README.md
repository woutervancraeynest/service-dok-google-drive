# service-dok-google-drive

Dok MCP service for managing a project-scoped Google Drive workspace and Google Docs documents.

## Architecture

```text
Dok Agent -> Dok MCP proxy -> This service -> Google Drive API / Google Docs API
```

Each project configures one Google Drive folder through `root_folder_id`. The service permits agents to manage files and descendant folders inside that subtree. Sharing, permissions, ownership, and public links are deliberately not exposed as tools and remain human-only.

## Configuration

The service receives the project configuration and OAuth tokens in the Dok service context:

```json
{
  "configuration": {
    "root_folder_id": "https://drive.google.com/drive/folders/FOLDER_ID"
  },
  "oauth_tokens": {
    "access_token": "...",
    "refresh_token": "...",
    "expires_at": 1735689600
  }
}
```

The platform supplies the Google OAuth client credentials as `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET`. Tokens are never configured in this repository or logged by the service.

## Local development

```bash
bundle install
bundle exec rspec
bundle exec puma -C config/puma.rb
curl http://localhost:8080/health
```

Google API calls are mocked in the test suite. A real account is only required for an integration smoke test after the Google Cloud OAuth application has been configured.

## Security boundary

OAuth scopes do not restrict access to a Drive folder. Every read and write resolves the requested resource and verifies that it is the configured root folder or a descendant. The root folder cannot be deleted, and resources cannot be moved outside it.

The service does not manage Google Drive sharing or permissions. Humans must perform those actions in Google Drive.

## Current tools

- `google_list_files`
- `google_search_files`
- `google_read_file`
- `google_read_document`
- `google_create_folder`
- `google_create_document`
- `google_create_document_from_template`
- `google_update_document`
- `google_move_file`
- `google_delete_file`
- `google_export_file`
