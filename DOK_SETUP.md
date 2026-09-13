# Dok setup

## Google Cloud OAuth client

Create an OAuth web application in Google Cloud and add Dok's callback URL:

```text
https://<dok-host>/oauth/callback
```

Configure the published service with this OAuth configuration:

```text
provider: google
authorize_url: https://accounts.google.com/o/oauth2/v2/auth
token_url: https://oauth2.googleapis.com/token
scope: https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents
```

Note: The `drive` scope (not `drive.file`) is required because agents manage pre-existing files in a user-selected folder. Folder-scope enforcement happens in the service, not via OAuth scopes.

For local development, use the local Dok callback URL configured by the Rails app.

## Project setup

1. Install and enable `Google Drive & Docs` in the project.
2. Configure the Google Drive root folder with its folder URL, for example:

   ```text
   https://drive.google.com/drive/folders/<folder-id>
   ```

3. Connect the Google account through the service's OAuth action.
4. Confirm that the service can list the root folder.

Agents can manage content inside the root folder and all descendant folders. Humans remain responsible for sharing, permissions, ownership, and public links.
