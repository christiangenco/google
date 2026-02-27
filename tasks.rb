#!/usr/bin/env ruby
# scripts/tasks.rb
#
# Purpose:
#   Google Tasks CLI with CRUD operations. Outputs compact JSON for LLM parsing.
#
# Usage:
#   bundle exec ruby scripts/tasks.rb <command> [options]
#
# Commands:
#   lists      - List task lists
#   list       - List tasks in a list (--list-id, --show-completed, --limit)
#   get        - Get single task (--list-id, --id)
#   create     - Create task (--list-id, --title, --notes, --due)
#   update     - Update task (--list-id, --id, --title, --notes, --due, --status)
#   complete   - Mark task complete (--list-id, --id)
#   delete     - Delete task (--list-id, --id)
#
# Environment:
#   - GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN (OAuth)
#   - Or GOOGLE_SERVICE_ACCOUNT_JSON / GOOGLE_CREDENTIALS_JSON
#
# Safety:
#   - create/update/complete/delete are destructive
#
# Notes:
#   - Outputs single-line JSON to stdout, logs to stderr
#   - Due dates should be ISO8601 format (date only, e.g., 2025-01-15)

require 'json'
require 'optparse'
require 'time'
require_relative 'lib/google_client'

def output(data)
  puts JSON.generate(data)
end

def success(data)
  output(ok: true, data: data)
  exit 0
end

def error(msg, code = 'ERROR', details = nil)
  output(ok: false, error: msg, code: code, details: details)
  exit 1
end

def extract_task(task)
  {
    id: task.id,
    title: task.title,
    notes: task.notes,
    status: task.status,
    due: task.due,
    completed: task.completed,
    parent: task.parent,
    position: task.position,
    updated: task.updated
  }
end

def extract_task_list(list)
  {
    id: list.id,
    title: list.title,
    updated: list.updated
  }
end

def check_help(usage_text)
  if ARGV.include?('--help') || ARGV.include?('-h')
    puts usage_text
    exit 0
  end
end

begin
  tasks = GoogleClient.tasks_service
  command = ARGV.shift
  options = {}

  case command
  when 'lists'
    check_help("Usage: google-cli tasks lists\n  List all task lists")
    result = tasks.list_tasklists(max_results: 100)
    lists = (result.items || []).map { |l| extract_task_list(l) }
    success(lists: lists)

  when 'list'
    check_help(<<~HELP)
      Usage: google-cli tasks list [options]
        List tasks in a list
        --list-id ID         Task list ID (default: @default)
        --show-completed     Include completed tasks
        --limit N            Max results (default: 100)
    HELP
    OptionParser.new do |opts|
      opts.on('--list-id ID') { |v| options[:list_id] = v }
      opts.on('--show-completed') { options[:show_completed] = true }
      opts.on('--limit N', Integer) { |v| options[:limit] = v }
    end.parse!

    list_id = options[:list_id] || '@default'
    limit = options[:limit] || 100

    result = tasks.list_tasks(list_id,
      max_results: limit,
      show_completed: options[:show_completed] || false,
      show_hidden: options[:show_completed] || false
    )

    items = (result.items || []).map { |t| extract_task(t) }
    success(tasks: items)

  when 'get'
    check_help(<<~HELP)
      Usage: google-cli tasks get --id TASK_ID [--list-id ID]
        Get a single task
        --id ID          Task ID (required)
        --list-id ID     Task list ID (default: @default)
    HELP
    OptionParser.new do |opts|
      opts.on('--list-id ID') { |v| options[:list_id] = v }
      opts.on('--id ID') { |v| options[:id] = v }
    end.parse!

    error('Missing --id', 'USAGE') unless options[:id]

    list_id = options[:list_id] || '@default'
    task = tasks.get_task(list_id, options[:id])
    success(extract_task(task))

  when 'create'
    check_help(<<~HELP)
      Usage: google-cli tasks create --title TITLE [options]
        Create a task
        --title TITLE    Task title (required)
        --notes NOTES    Task notes
        --due DATE       Due date (ISO8601, e.g., 2025-01-15)
        --parent ID      Parent task ID (for subtasks)
        --list-id ID     Task list ID (default: @default)
    HELP
    OptionParser.new do |opts|
      opts.on('--list-id ID') { |v| options[:list_id] = v }
      opts.on('--title TITLE') { |v| options[:title] = v }
      opts.on('--notes NOTES') { |v| options[:notes] = v }
      opts.on('--due DATE') { |v| options[:due] = v }
      opts.on('--parent ID') { |v| options[:parent] = v }
    end.parse!

    error('Missing --title', 'USAGE') unless options[:title]

    list_id = options[:list_id] || '@default'

    task = Google::Apis::TasksV1::Task.new(
      title: options[:title],
      notes: options[:notes]
    )
    task.due = Time.parse(options[:due]).utc.iso8601 if options[:due]

    result = tasks.insert_task(list_id, task, parent: options[:parent])
    success(extract_task(result))

  when 'update'
    check_help(<<~HELP)
      Usage: google-cli tasks update --id TASK_ID [options]
        Update a task
        --id ID          Task ID (required)
        --title TITLE    New title
        --notes NOTES    New notes
        --due DATE       New due date
        --status STATUS  New status (needsAction, completed)
        --list-id ID     Task list ID (default: @default)
    HELP
    OptionParser.new do |opts|
      opts.on('--list-id ID') { |v| options[:list_id] = v }
      opts.on('--id ID') { |v| options[:id] = v }
      opts.on('--title TITLE') { |v| options[:title] = v }
      opts.on('--notes NOTES') { |v| options[:notes] = v }
      opts.on('--due DATE') { |v| options[:due] = v }
      opts.on('--status STATUS') { |v| options[:status] = v }
    end.parse!

    error('Missing --id', 'USAGE') unless options[:id]

    list_id = options[:list_id] || '@default'
    task = tasks.get_task(list_id, options[:id])

    task.title = options[:title] if options[:title]
    task.notes = options[:notes] if options[:notes]
    task.due = Time.parse(options[:due]).utc.iso8601 if options[:due]
    task.status = options[:status] if options[:status]

    result = tasks.update_task(list_id, options[:id], task)
    success(extract_task(result))

  when 'complete'
    check_help(<<~HELP)
      Usage: google-cli tasks complete --id TASK_ID [--list-id ID]
        Mark a task as complete
        --id ID          Task ID (required)
        --list-id ID     Task list ID (default: @default)
    HELP
    OptionParser.new do |opts|
      opts.on('--list-id ID') { |v| options[:list_id] = v }
      opts.on('--id ID') { |v| options[:id] = v }
    end.parse!

    error('Missing --id', 'USAGE') unless options[:id]

    list_id = options[:list_id] || '@default'
    task = tasks.get_task(list_id, options[:id])
    task.status = 'completed'

    result = tasks.update_task(list_id, options[:id], task)
    success(extract_task(result))

  when 'delete'
    check_help(<<~HELP)
      Usage: google-cli tasks delete --id TASK_ID [--list-id ID]
        Delete a task
        --id ID          Task ID (required)
        --list-id ID     Task list ID (default: @default)
    HELP
    OptionParser.new do |opts|
      opts.on('--list-id ID') { |v| options[:list_id] = v }
      opts.on('--id ID') { |v| options[:id] = v }
    end.parse!

    error('Missing --id', 'USAGE') unless options[:id]

    list_id = options[:list_id] || '@default'
    tasks.delete_task(list_id, options[:id])
    success(deleted: true, id: options[:id])

  when '--help', '-h', 'help', nil
    puts <<~HELP
      google-cli tasks - Google Tasks CLI

      Commands:
        lists      List task lists
        list       List tasks (--list-id, --show-completed, --limit)
        get        Get single task (--list-id, --id)
        create     Create task (--title, --notes, --due, --list-id)
        update     Update task (--id, --title, --notes, --due, --status)
        complete   Mark task complete (--id, --list-id)
        delete     Delete task (--id, --list-id)

      Run: google-cli tasks <command> --help for details
    HELP
    exit 0

  else
    error("Unknown command: #{command}", 'USAGE',
      'Commands: lists, list, get, create, update, complete, delete')
  end

rescue Google::Apis::AuthorizationError => e
  error('Authentication failed', 'AUTH', e.message)
rescue Signet::AuthorizationError => e
  error('Authorization error', 'AUTH', e.message)
rescue => e
  error(e.message, 'ERROR', e.backtrace.first(3).join("\n"))
end
