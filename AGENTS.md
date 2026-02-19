# google

Ruby CLIs for Gmail, Calendar, Drive, Tasks. All output JSON. Run from `~/tools/google`.

## emails.rb

```
bundle exec ruby emails.rb <command> [options]

list       [--label LABEL] [--q QUERY] [--limit N] [--page-token TOKEN]
starred    [--limit N] [--page-token TOKEN]
search     (alias for list --q)
get        --id ID
thread     --id THREAD_ID
send       --to ADDR --subject SUBJ [--text TEXT] [--html HTML] [--cc CC] [--bcc BCC]
reply      --id ID [--text TEXT] [--html HTML]
draft      --id ID [--text TEXT] [--html HTML]           # reply draft
draft      --to ADDR --subject SUBJ [--text TEXT] [--html HTML] [--cc CC] [--bcc BCC]  # new draft
drafts list  [--limit N] [--page-token TOKEN]
drafts send  --id DRAFT_ID
delete-draft --id DRAFT_ID
star       --id ID
unstar     --id ID
read       --id ID
unread     --id ID
archive    --id ID
trash      --id ID
attachment --message-id ID --attachment-id ID [--output PATH]
labels     [--list] [--create NAME]
```

```bash
bundle exec ruby emails.rb list --limit 10
bundle exec ruby emails.rb list --q "from:alice is:unread"
bundle exec ruby emails.rb get --id 18f1a2b3c4d5e6f7
bundle exec ruby emails.rb send --to "bob@x.com" --subject "Hi" --text "Hello"
bundle exec ruby emails.rb reply --id 18f1a2b3c4d5e6f7 --text "Thanks"
bundle exec ruby emails.rb archive --id 18f1a2b3c4d5e6f7
```

## calendar.rb

```
bundle exec ruby calendar.rb <command> [options]

list       [--from DATETIME] [--to DATETIME] [--q QUERY] [--limit N] [--calendar-id ID] [--page-token TOKEN]
search     (alias for list --q)
get        --id ID [--calendar-id ID]
create     --summary TITLE --start DATETIME --end DATETIME [--all-day] [--description DESC] [--location LOC] [--attendees EMAILS] [--calendar-id ID]
update     --id ID [--summary TITLE] [--start DATETIME] [--end DATETIME] [--all-day] [--description DESC] [--location LOC] [--attendees EMAILS] [--calendar-id ID]
delete     --id ID [--calendar-id ID]
calendars
freebusy   --from DATETIME --to DATETIME [--calendars IDS]
quick-add  --text TEXT [--calendar-id ID]
```

```bash
bundle exec ruby calendar.rb list
bundle exec ruby calendar.rb list --from "2025-03-01" --to "2025-03-31"
bundle exec ruby calendar.rb create --summary "Standup" --start "2025-03-15T09:00:00" --end "2025-03-15T09:30:00"
bundle exec ruby calendar.rb quick-add --text "Dentist Friday 2pm"
bundle exec ruby calendar.rb freebusy --from "2025-03-15T00:00:00" --to "2025-03-16T00:00:00"
```

## drive.rb

```
bundle exec ruby drive.rb <command> [options]

list        [--q QUERY] [--limit N] [--folder-id ID] [--page-token TOKEN]
search      --q QUERY [--limit N] [--page-token TOKEN]
folders     [--limit N] [--page-token TOKEN]
get         --id ID
download    --id ID [--output PATH] [--export-format FMT]
upload      --path PATH [--name NAME] [--folder-id ID] [--mime-type TYPE]
create      --name NAME [--folder-id ID] [--mime-type TYPE]
mkdir       --name NAME [--folder-id ID]
update      --id ID [--name NAME] [--description DESC]
delete      --id ID
copy        --id ID [--name NAME] [--folder-id ID]
move        --id ID --folder-id ID
share       --id ID (--email ADDR | --anyone) [--role ROLE]
unshare     --id ID --permission-id PID
permissions --id ID
```

Export formats: `txt`, `pdf`, `docx`, `html`, `csv`, `xlsx`, `pptx`

```bash
bundle exec ruby drive.rb list --limit 10
bundle exec ruby drive.rb search --q "quarterly report"
bundle exec ruby drive.rb download --id FILE_ID --export-format pdf --output report.pdf
bundle exec ruby drive.rb upload --path ./doc.pdf --folder-id FOLDER_ID
bundle exec ruby drive.rb share --id FILE_ID --email "bob@x.com" --role writer
```

## tasks.rb

```
bundle exec ruby tasks.rb <command> [options]

lists
list       [--list-id ID] [--show-completed] [--limit N]
get        --id ID [--list-id ID]
create     --title TITLE [--list-id ID] [--notes NOTES] [--due DATE] [--parent ID]
update     --id ID [--list-id ID] [--title TITLE] [--notes NOTES] [--due DATE] [--status STATUS]
complete   --id ID [--list-id ID]
delete     --id ID [--list-id ID]
```

```bash
bundle exec ruby tasks.rb lists
bundle exec ruby tasks.rb list --show-completed
bundle exec ruby tasks.rb create --title "Buy milk" --due "2025-03-15"
bundle exec ruby tasks.rb complete --id TASK_ID
```

## Auth

Requires `.env` with `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN`.
