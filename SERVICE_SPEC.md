# Google Drive & Docs Dok Service

This service follows the Dok Service contract in `docker/service-template/SERVICE_SPEC.md` in the Dok repository.

## OAuth

The service expects Google OAuth tokens in `context.oauth_tokens` and platform-level OAuth client credentials in `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET`.

Required Google capabilities are Drive file access and Google Docs editing. The Dok platform owns token storage and the service uses the refresh token when an access token expires.

## Project folder

`context.configuration.root_folder_id` accepts a Google Drive folder ID or a `drive.google.com/drive/folders/...` URL. All tools enforce that resources belong to this folder or its descendant folders.

The following operations are not supported:

- changing Google Drive permissions;
- sharing files or folders;
- changing ownership;
- creating public links;
- deleting the configured root folder;
- moving resources outside the configured root folder.

## API behavior

Google Docs writes use `documents.batchUpdate`. Callers should pass `required_revision_id` from `google_read_document` to prevent stale writes from overwriting human edits.

Non-folder binary or text files can be read through `google_read_file` with a 5 MB response limit. Google Docs are returned as text through the same tool; use `google_read_document` when the current revision is also required.

## Table row operations

`google_append_table_row` appends a row to a table inside a Google Docs document. The agent provides cell values and an optional deduplication rule; the tool finds the table by its header cells, computes all structural indices via the Docs API with `includeTabsContent=true`, and verifies the result.

The `cells` parameter is an array of string values, one per column. Deduplication is optional via the `dedup` parameter: `{ "column_index": 0, "match": "date" }` normalises dates before comparing, `"exact"` compares trimmed text literally, and `"none"` disables dedup.

The tool returns one of these statuses:

- `inserted` — row added and verified.
- `duplicate` — a row with the same dedup value already exists; no write performed.
- `revision_conflict` — the document changed since it was read; the agent should re-read.
- `table_not_found` — no table matches the given header cells.
- `malformed_table` — table found but has an unexpected structure.
- `partial_failure` — row was inserted but cell fill failed.

`google_analyze_document_tables` is a read-only tool that inspects the table structure of a document and returns tables, rows, text blocks outside tables, and detected date patterns.
