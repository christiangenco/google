#!/usr/bin/env ruby
# tools/google/calendar.rb
#
# Purpose:
#   Google Calendar CLI with CRUD operations. Outputs compact JSON for LLM parsing.
#
# Usage:
#   bundle exec ruby tools/google/calendar.rb <command> [options]
#
# Commands:
#   list       - List events (--from, --to, --q, --limit, --page-token, --calendar-id)
#   get        - Get single event (--id, --calendar-id)
#   create     - Create event (--summary, --start, --end, --all-day, --description, --location, --attendees)
#   update     - Update event (--id, plus any fields to change, --all-day)
#   delete     - Delete event (--id, --calendar-id)
#   search     - Alias for list --q
#   calendars  - List all calendars
#   freebusy   - Check availability (--from, --to, --calendars)
#   quick-add  - Natural language event creation (--text, --calendar-id)
#
# Environment:
#   - GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN (OAuth)
#   - Or GOOGLE_SERVICE_ACCOUNT_JSON / GOOGLE_CREDENTIALS_JSON
#
# Safety:
#   - create/update/delete are destructive
#
# Notes:
#   - Outputs single-line JSON to stdout, logs to stderr
#   - Dates should be ISO8601 format

require 'json'
require 'optparse'
require 'time'
require_relative 'lib/google_client'

class CalendarCLI
  def initialize
    @calendar = GoogleClient.calendar_service
  end

  # ── Output ──

  def success(data)
    puts JSON.generate(ok: true, data: data)
    exit 0
  end

  def error(msg, code = 'ERROR', details = nil)
    puts JSON.generate(ok: false, error: msg, code: code, details: details)
    exit 1
  end

  # ── Helpers ──

  def extract_event(event, verbose: false)
    desc = event.description
    unless verbose
      desc = truncate_description(desc)
    end
    result = {
      id: event.id,
      summary: event.summary,
      start: event.start&.date_time&.to_s || event.start&.date,
      end: event.end&.date_time&.to_s || event.end&.date,
      status: event.status,
      location: event.location,
      description: desc,
      attendees: (event.attendees || []).map { |a| { email: a.email, response: a.response_status } },
      organizer: event.organizer ? { email: event.organizer.email, self: event.organizer.self? } : nil,
      html_link: event.html_link,
      recurring_event_id: event.recurring_event_id,
      reminders: extract_reminders(event),
      conference: extract_conference(event)
    }.compact
    result
  end

  def truncate_description(desc)
    return desc if desc.nil?
    # Strip long meeting URLs and truncate to 200 chars
    cleaned = desc.gsub(/https?:\/\/teams\.microsoft\.com\/\S+/, '[Teams link]')
                  .gsub(/https?:\/\/meet\.google\.com\/\S+/, '[Meet link]')
                  .gsub(/https?:\/\/zoom\.us\/\S+/, '[Zoom link]')
    cleaned.length > 200 ? cleaned[0..197] + '...' : cleaned
  end

  def extract_reminders(event)
    return nil unless event.reminders
    if event.reminders.use_default
      { use_default: true }
    elsif event.reminders.overrides&.any?
      { overrides: event.reminders.overrides.map { |r| { method: r.reminder_method, minutes: r.minutes } } }
    end
  end

  def extract_conference(event)
    cd = event.conference_data
    return nil unless cd
    result = {}
    result[:solution] = cd.conference_solution&.name if cd.conference_solution
    if cd.entry_points&.any?
      result[:entry_points] = cd.entry_points.map do |ep|
        { type: ep.entry_point_type, uri: ep.uri, label: ep.label }.compact
      end
    end
    result.empty? ? nil : result
  end

  def parse_datetime(str)
    return nil unless str
    Google::Apis::CalendarV3::EventDateTime.new(date_time: Time.parse(str).iso8601)
  end

  def parse_date(str)
    return nil unless str
    Google::Apis::CalendarV3::EventDateTime.new(date: str)
  end

  # ── Commands ──

  def list(options)
    cal_id = options[:calendar_id] || 'primary'
    time_min = options[:from] ? Time.parse(options[:from]).iso8601 : Time.now.iso8601
    time_max = options[:to] ? Time.parse(options[:to]).iso8601 : (Time.now + 7 * 24 * 3600).iso8601
    limit = options[:limit] || 20
    verbose = options[:verbose] || false

    list_opts = {
      time_min: time_min,
      time_max: time_max,
      max_results: limit,
      single_events: true,
      order_by: 'startTime'
    }
    list_opts[:q] = options[:q] if options[:q]
    list_opts[:page_token] = options[:page_token] if options[:page_token]

    result = @calendar.list_events(cal_id, **list_opts)

    events = (result.items || []).map { |e| extract_event(e, verbose: verbose) }
    data = { events: events }
    # Only include next_page_token if --page-token was used or there's pagination
    data[:next_page_token] = result.next_page_token if options[:page_token] || verbose
    success(data)
  end

  def get(options)
    error('Missing --id', 'USAGE') unless options[:id]

    cal_id = options[:calendar_id] || 'primary'
    verbose = options[:verbose] || false
    event = @calendar.get_event(cal_id, options[:id])
    success(extract_event(event, verbose: verbose))
  end

  def create(options)
    error('Missing --summary', 'USAGE') unless options[:summary]
    error('Missing --start', 'USAGE') unless options[:start]
    error('Missing --end', 'USAGE') unless options[:end]

    cal_id = options[:calendar_id] || 'primary'

    event = Google::Apis::CalendarV3::Event.new(
      summary: options[:summary],
      description: options[:description],
      location: options[:location]
    )

    if options[:all_day]
      event.start = parse_date(options[:start])
      event.end = parse_date(options[:end])
    else
      event.start = parse_datetime(options[:start])
      event.end = parse_datetime(options[:end])
    end

    if options[:attendees]
      emails = options[:attendees].split(',').map(&:strip)
      event.attendees = emails.map { |e| Google::Apis::CalendarV3::EventAttendee.new(email: e) }
    end

    result = @calendar.insert_event(cal_id, event)
    success(extract_event(result))
  end

  def update(options)
    error('Missing --id', 'USAGE') unless options[:id]

    cal_id = options[:calendar_id] || 'primary'
    event = @calendar.get_event(cal_id, options[:id])

    event.summary = options[:summary] if options[:summary]
    event.description = options[:description] if options[:description]
    event.location = options[:location] if options[:location]

    if options[:start]
      event.start = options[:all_day] ? parse_date(options[:start]) : parse_datetime(options[:start])
    end
    if options[:end]
      event.end = options[:all_day] ? parse_date(options[:end]) : parse_datetime(options[:end])
    end

    if options[:attendees]
      emails = options[:attendees].split(',').map(&:strip)
      event.attendees = emails.map { |e| Google::Apis::CalendarV3::EventAttendee.new(email: e) }
    end

    result = @calendar.update_event(cal_id, options[:id], event)
    success(extract_event(result))
  end

  def delete(options)
    error('Missing --id', 'USAGE') unless options[:id]

    cal_id = options[:calendar_id] || 'primary'
    @calendar.delete_event(cal_id, options[:id])
    success(deleted: true, id: options[:id])
  end

  def calendars(_options)
    result = @calendar.list_calendar_lists
    cals = (result.items || []).map do |cal|
      {
        id: cal.id,
        summary: cal.summary,
        primary: cal.primary || false,
        access_role: cal.access_role
      }
    end
    success(calendars: cals)
  end

  def freebusy(options)
    error('Missing --from', 'USAGE') unless options[:from]
    error('Missing --to', 'USAGE') unless options[:to]

    cal_ids = if options[:calendars]
                options[:calendars].split(',').map(&:strip)
              else
                ['primary']
              end

    request = Google::Apis::CalendarV3::FreeBusyRequest.new(
      time_min: Time.parse(options[:from]).iso8601,
      time_max: Time.parse(options[:to]).iso8601,
      items: cal_ids.map { |id| Google::Apis::CalendarV3::FreeBusyRequestItem.new(id: id) }
    )

    result = @calendar.query_freebusy(request)

    busy_data = {}
    (result.calendars || {}).each do |cal_id, cal_info|
      busy_data[cal_id] = (cal_info.busy || []).map do |period|
        { start: period.start.to_s, end: period.end.to_s }
      end
    end

    success(busy: busy_data)
  end

  def quick_add(options)
    error('Missing --text', 'USAGE') unless options[:text]

    cal_id = options[:calendar_id] || 'primary'
    result = @calendar.quick_add_event(cal_id, options[:text])
    success(extract_event(result))
  end
end

# ── CLI dispatch ──

def parse_options(*specs)
  options = {}
  parser = OptionParser.new do |opts|
    specs.each do |name, flag, type|
      if type
        opts.on(flag, type) { |v| options[name] = v }
      else
        opts.on(flag) { |v| options[name] = v }
      end
    end
  end
  parser.parse!
  options
end

CALENDAR_ID_OPT = [:calendar_id, '--calendar-id ID', nil].freeze

begin
  cli = CalendarCLI.new
  command = ARGV.shift

  case command
  when 'list', 'search'
    options = parse_options(
      CALENDAR_ID_OPT,
      [:from, '--from DATETIME', nil],
      [:to, '--to DATETIME', nil],
      [:q, '--q QUERY', nil],
      [:limit, '--limit N', Integer],
      [:page_token, '--page-token TOKEN', nil],
      [:verbose, '--verbose', nil]
    )
    cli.list(options)

  when 'get'
    options = parse_options(
      CALENDAR_ID_OPT,
      [:id, '--id ID', nil],
      [:verbose, '--verbose', nil]
    )
    cli.get(options)

  when 'create'
    options = parse_options(
      CALENDAR_ID_OPT,
      [:summary, '--summary TITLE', nil],
      [:start, '--start DATETIME', nil],
      [:end, '--end DATETIME', nil],
      [:description, '--description DESC', nil],
      [:location, '--location LOC', nil],
      [:attendees, '--attendees EMAILS', nil],
      [:all_day, '--all-day', nil]
    )
    cli.create(options)

  when 'update'
    options = parse_options(
      CALENDAR_ID_OPT,
      [:id, '--id ID', nil],
      [:summary, '--summary TITLE', nil],
      [:start, '--start DATETIME', nil],
      [:end, '--end DATETIME', nil],
      [:description, '--description DESC', nil],
      [:location, '--location LOC', nil],
      [:attendees, '--attendees EMAILS', nil],
      [:all_day, '--all-day', nil]
    )
    cli.update(options)

  when 'delete'
    options = parse_options(
      CALENDAR_ID_OPT,
      [:id, '--id ID', nil]
    )
    cli.delete(options)

  when 'calendars'
    options = parse_options()
    cli.calendars(options)

  when 'freebusy'
    options = parse_options(
      [:from, '--from DATETIME', nil],
      [:to, '--to DATETIME', nil],
      [:calendars, '--calendars IDS', nil]
    )
    cli.freebusy(options)

  when 'quick-add'
    options = parse_options(
      CALENDAR_ID_OPT,
      [:text, '--text TEXT', nil]
    )
    cli.quick_add(options)

  else
    cli.error("Unknown command: #{command}", 'USAGE',
      'Commands: list, get, create, update, delete, search, calendars, freebusy, quick-add')
  end

rescue Google::Apis::AuthorizationError => e
  puts JSON.generate(ok: false, error: 'Authentication failed', code: 'AUTH', details: e.message)
  exit 1
rescue Signet::AuthorizationError => e
  puts JSON.generate(ok: false, error: 'Authorization error', code: 'AUTH', details: e.message)
  exit 1
rescue StandardError => e
  puts JSON.generate(ok: false, error: e.message, code: 'ERROR', details: e.backtrace.first(3).join("\n"))
  exit 1
end
