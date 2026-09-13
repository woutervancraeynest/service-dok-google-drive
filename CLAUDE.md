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

## Verification

```bash
bundle exec rspec
```
