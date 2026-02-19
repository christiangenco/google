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

begin
  tasks = GoogleClient.tasks_service
  command = ARGV.shift
  options = {}

  case command
  when 'lists'
    result = tasks.list_tasklists(max_results: 100)
    lists = (result.items || []).map { |l| extract_task_list(l) }
    success(lists: lists)

  when 'list'
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
    OptionParser.new do |opts|
      opts.on('--list-id ID') { |v| options[:list_id] = v }
      opts.on('--id ID') { |v| options[:id] = v }
    end.parse!

    error('Missing --id', 'USAGE') unless options[:id]

    list_id = options[:list_id] || '@default'
    task = tasks.get_task(list_id, options[:id])
    success(extract_task(task))

  when 'create'
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
    OptionParser.new do |opts|
      opts.on('--list-id ID') { |v| options[:list_id] = v }
      opts.on('--id ID') { |v| options[:id] = v }
    end.parse!

    error('Missing --id', 'USAGE') unless options[:id]

    list_id = options[:list_id] || '@default'
    tasks.delete_task(list_id, options[:id])
    success(deleted: true, id: options[:id])

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
