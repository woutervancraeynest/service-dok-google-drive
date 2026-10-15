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

Every read and write returns `revision_id` and a short `revision_token` (`r-` + 12 hex characters, derived from a SHA-256 of the revision ID). All `required_revision_id` parameters accept either value; agents should pass the token, because Docs revision IDs are about 100 random characters and language models regularly drop or alter characters when copying them. The service resolves the token to the full revision ID and still enforces it through Docs `writeControl`.

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

## Cell-targeted table edits

`google_inspect_document_tables` and `google_update_table_cell` fill existing cells in a document such as a leersteunplan. The service reads the Docs structure (`includeTabsContent=true`), resolves the target cell, and computes all `deleteContentRange`/`insertText` indices. Agents never pass or compute indices.

### Inspect first

```json
{ "tool": "google_inspect_document_tables", "params": { "file_id": "DOC_ID" } }
```

Returns `revision_id`, `revision_token` and per table a `table_id` (`t.0/2`), `label`, `section_heading`, `preceding_text` and every cell with `cell_id` (`t.0/2/1/1`), `text` and `state` (`empty`, `placeholder` or `filled`). IDs are positions and only valid for the revision they were inspected at; the mandatory revision check enforces that.

### Fill a cell by row label and column header

```json
{
  "tool": "google_update_table_cell",
  "params": {
    "file_id": "DOC_ID",
    "table_selector": { "section_heading": "Agenda" },
    "row_selector": { "cell_text": "Opstartgesprek" },
    "column_selector": { "header_text": "Datum" },
    "value": "09/10/2026",
    "required_revision_id": "r-3fa9c01b7d2e",
    "dry_run": true
  }
}
```

Repeat without `dry_run`, then for `"header_text": "Aanwezigen"` using the `revision_token` returned by the previous update.

- `table_selector` (optional, all keys must match): `table_id`, `header_cells` (complete texts of one row), `section_heading` (nearest heading above the table, the paragraph directly above it, or the first cell), `contains_text` (exact text of any cell).
- `row_selector`: `cell_text` matched against column `column_index` (default 0), or `row_index` (requires a `table_selector`).
- `column_selector`: `header_text` (searched in rows above the target row, nearest first, so title rows do not interfere; optional `header_row_index`) and/or `index`.

Matching is case-insensitive and ignores surrounding whitespace, non-breaking spaces, a trailing colon and Unicode composition differences. The combined selectors must resolve to exactly one cell.

### Tables without column headers

Use an anchor cell and a relation (`right`, `below`, or `next` = right, else first cell of the next row):

```json
{
  "table_selector": { "section_heading": "Doelstellingen" },
  "cell_selector": { "anchor_text": "Doelstellingen", "relation": "below" },
  "value": "Leest vlot een korte tekst.",
  "required_revision_id": "r-3fa9c01b7d2e"
}
```

Or use `"cell_selector": { "cell_id": "t.0/4/1/0" }` from the inspection.

### Safety rules

- Only an existing cell is changed; rows are never inserted.
- Empty cells, filler (`___`, `…`), `<token>` placeholders and Word placeholders such as "Klik of tik om een datum in te voeren." may be filled. Extra placeholder texts can be passed with `placeholders`. Other content, smart chips (date, person) included, is only overwritten with `replace_existing: true`. Cells with nested tables or open suggestions (suggested insertions/deletions) are never edited; inspection marks the latter with `has_suggestions: true`.
- `required_revision_id` (token or full ID) is mandatory. The revision is checked before resolving and enforced again by Docs `writeControl` during the write.
- After a rejected write the service compares the document content before and after, not only the revision ID (Google may change the ID without a content change). Unchanged content means `write_failed`, unless Google reports a revision error; Google's error is returned in `write_error` and logged to stderr.
- The write is a single `batchUpdate` without automatic retries. Afterwards the service re-reads the document and verifies that the target cell holds the value, that the table structure is unchanged, and that no other cell or text outside tables changed.

### Result

```json
{
  "status": "updated",
  "written": true,
  "file_id": "...",
  "table": "Agenda",
  "table_id": "t.0/0",
  "row": "Opstartgesprek",
  "row_index": 1,
  "column": "Datum",
  "column_index": 1,
  "cell_id": "t.0/0/1/1",
  "cell_state": "placeholder",
  "old_value": "Klik of tik om een datum in te voeren.",
  "new_value": "09/10/2026",
  "revision_id": "...",
  "revision_token": "r-...",
  "verification": { "ok": true, "checks": { "...": true }, "problems": [] }
}
```

| Status | Meaning | Written |
| --- | --- | --- |
| `updated` | Value written and verified. | yes |
| `would_update` | Dry run; everything checked. | no |
| `unchanged` | Cell already holds the value. | no |
| `table_not_found` | No table matches; `available_tables` lists the tables. | no |
| `row_not_found` / `column_not_found` / `cell_not_found` | Selector does not resolve. | no |
| `ambiguous_match` | Several cells match; `candidates` helps refine the selector. | no |
| `cell_not_empty` | Meaningful content present and `replace_existing` not set. | no |
| `unsupported_cell_content` | Cell contains a nested table or open suggestions. | no |
| `revision_conflict` | Document changed; `revision_id`/`revision_token` are current. `phase` is `pre_check` or `write`. A pre-check conflict includes `expected_revision_id` and `current_revision_id`, and `likely_copy_error: true` when the supplied ID looks like a mis-copied current ID. | no |
| `invalid_selector` / `invalid_request` | Invalid parameters. | no |
| `write_failed` | Google rejected the write; the document is unchanged. `write_error` holds Google's status code and message. | no |
| `verification_failed` | Written, but verification found a problem (see `verification`). Also returned (with `revision_id: null`) when the document cannot be re-read after the write. `written` is `"unknown"` when the outcome is unclear, e.g. a concurrent edit or a failed write response followed by a failed re-read. | yes / unknown |

Inserted text inherits the formatting at the insertion point. When a grey Word placeholder is replaced, check the formatting in the document.
