# google

Ruby CLIs for Gmail, Google Calendar, Google Drive, and Google Tasks. All output single-line JSON to stdout.

## Setup

```bash
bundle install
```

Create a `.env` file:

```
GOOGLE_CLIENT_ID=your-client-id
GOOGLE_CLIENT_SECRET=your-client-secret
GOOGLE_REFRESH_TOKEN=your-refresh-token
```

Alternatively, set `GOOGLE_SERVICE_ACCOUNT_JSON` or `GOOGLE_CREDENTIALS_JSON` for service account / OAuth JSON auth.

## Usage

### emails.rb — Gmail

```bash
# List inbox
bundle exec ruby emails.rb list
bundle exec ruby emails.rb list --limit 5 --label INBOX

# Search
bundle exec ruby emails.rb list --q "from:alice subject:invoice"

# Read
bundle exec ruby emails.rb get --id MESSAGE_ID
bundle exec ruby emails.rb thread --id THREAD_ID

# Send & reply
bundle exec ruby emails.rb send --to "bob@example.com" --subject "Hello" --text "Hi Bob"
bundle exec ruby emails.rb reply --id MESSAGE_ID --text "Thanks!"

# Drafts
bundle exec ruby emails.rb draft --to "bob@example.com" --subject "Draft" --text "WIP"
bundle exec ruby emails.rb draft --id MESSAGE_ID --text "Draft reply"
bundle exec ruby emails.rb drafts list
bundle exec ruby emails.rb drafts send --id DRAFT_ID
bundle exec ruby emails.rb delete-draft --id DRAFT_ID

# Organize
bundle exec ruby emails.rb star --id MESSAGE_ID
bundle exec ruby emails.rb unstar --id MESSAGE_ID
bundle exec ruby emails.rb read --id MESSAGE_ID
bundle exec ruby emails.rb unread --id MESSAGE_ID
bundle exec ruby emails.rb archive --id MESSAGE_ID
bundle exec ruby emails.rb trash --id MESSAGE_ID

# Labels
bundle exec ruby emails.rb labels
bundle exec ruby emails.rb labels --create "My Label"

# Attachments
bundle exec ruby emails.rb attachment --message-id MSG_ID --attachment-id ATT_ID --output file.pdf
```

### calendar.rb — Google Calendar

```bash
# List events (defaults to next 7 days)
bundle exec ruby calendar.rb list
bundle exec ruby calendar.rb list --from "2025-03-01" --to "2025-03-31" --limit 50

# CRUD
bundle exec ruby calendar.rb get --id EVENT_ID
bundle exec ruby calendar.rb create --summary "Meeting" --start "2025-03-15T10:00:00" --end "2025-03-15T11:00:00"
bundle exec ruby calendar.rb create --summary "Vacation" --start "2025-03-20" --end "2025-03-22" --all-day
bundle exec ruby calendar.rb update --id EVENT_ID --summary "Updated title"
bundle exec ruby calendar.rb delete --id EVENT_ID

# Quick add (natural language)
bundle exec ruby calendar.rb quick-add --text "Lunch with Alice tomorrow at noon"

# Other
bundle exec ruby calendar.rb calendars
bundle exec ruby calendar.rb freebusy --from "2025-03-15T00:00:00" --to "2025-03-16T00:00:00"
```

### drive.rb — Google Drive

```bash
# Browse
bundle exec ruby drive.rb list
bundle exec ruby drive.rb list --folder-id FOLDER_ID --limit 50
bundle exec ruby drive.rb folders
bundle exec ruby drive.rb search --q "quarterly report"

# Read
bundle exec ruby drive.rb get --id FILE_ID
bundle exec ruby drive.rb download --id FILE_ID --output report.pdf
bundle exec ruby drive.rb download --id GDOC_ID --export-format txt

# Write
bundle exec ruby drive.rb upload --path ./file.pdf --folder-id FOLDER_ID
bundle exec ruby drive.rb create --name "New Doc"
bundle exec ruby drive.rb mkdir --name "New Folder"
bundle exec ruby drive.rb update --id FILE_ID --name "Renamed"
bundle exec ruby drive.rb copy --id FILE_ID --name "Copy of File"
bundle exec ruby drive.rb move --id FILE_ID --folder-id DEST_FOLDER_ID
bundle exec ruby drive.rb delete --id FILE_ID

# Sharing
bundle exec ruby drive.rb share --id FILE_ID --email "bob@example.com" --role writer
bundle exec ruby drive.rb share --id FILE_ID --anyone
bundle exec ruby drive.rb permissions --id FILE_ID
bundle exec ruby drive.rb unshare --id FILE_ID --permission-id PERM_ID
```

### tasks.rb — Google Tasks

```bash
# List task lists and tasks
bundle exec ruby tasks.rb lists
bundle exec ruby tasks.rb list
bundle exec ruby tasks.rb list --list-id LIST_ID --show-completed

# CRUD
bundle exec ruby tasks.rb get --id TASK_ID
bundle exec ruby tasks.rb create --title "Buy groceries" --due "2025-03-15" --notes "Milk, eggs"
bundle exec ruby tasks.rb update --id TASK_ID --title "Updated title"
bundle exec ruby tasks.rb complete --id TASK_ID
bundle exec ruby tasks.rb delete --id TASK_ID
```

## Output Format

All commands return JSON: `{"ok":true,"data":{...}}` on success, `{"ok":false,"error":"...","code":"..."}` on failure.
