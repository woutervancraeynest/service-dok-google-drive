# Google Drive & Docs Dok Service

This repository contains a Dok Service that exposes Google Drive and Google Docs operations through the Dok MCP proxy.

## Rules

- Keep the configured `root_folder_id` as the hard security boundary.
- Validate every resource ID before reading or writing.
- Never add sharing, permission, ownership, or public-link operations to the agent tools.
- Never log OAuth access tokens or refresh tokens.
- Use Google Drive API for file and folder operations.
- Use Google Docs API `batchUpdate` for document content changes.
- Require a revision ID for agent edits whenever one was returned by a preceding read.
- Keep API responses bounded; do not return unbounded Drive listings or exports.
- Agents must never compute Google Docs indices. Use `google_append_table_row` to add rows and `google_update_table_cell` to fill existing cells; both compute all structural indices server-side.
- `google_update_table_cell` must never insert rows, overwrite meaningful content without `replace_existing`, or write when selectors are ambiguous or the revision is stale. Every write is verified by re-reading the document.
- Never return Docs indices from `google_inspect_document_tables`; agents address cells with semantic selectors or `cell_id`.
- Always use `includeTabsContent: true` and `tabId` for structural Docs operations. Never use `endOfSegmentLocation` for table content.
- Deduplication is configurable per call (`dedup.match`: `date`, `exact`, or `none`). The tool writes cell values verbatim; normalisation only applies to the dedup comparison.

## Architecture

- `lib/google_workspace.rb` — Google Drive and Docs API client with scope enforcement.
- `lib/doc_tables.rb` — Pure helpers for structural table operations (parsing, matching, dedup, verification). No network calls.
- `lib/doc_table_cells.rb` — Pure helpers for cell-targeted edits (selector resolution, cell state, inspection, post-write verification). No network calls.
- `spec/support/fake_docs_model.rb` — In-memory Docs model that applies `deleteContentRange`/`insertText` with UTF-16 indices; use it for write-path specs.
- `lib/tools/` — Thin tool handlers that delegate to the client.
- `app.rb` — Sinatra endpoint that dispatches tool calls.
- `manifest.json` — MCP tool definitions and OAuth/configuration schema.

## Verification

```bash
bundle exec rspec
```
