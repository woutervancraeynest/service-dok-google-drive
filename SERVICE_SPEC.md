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
