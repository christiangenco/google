#!/usr/bin/env ruby
# tools/google/emails.rb
#
# Purpose:
#   Gmail CLI with CRUD operations for emails. Outputs compact JSON for LLM parsing.
#
# Usage:
#   bundle exec ruby tools/google/emails.rb <command> [options]
#
# Commands:
#   list         - List messages (--label, --q, --limit, --page-token)
#   starred      - List starred messages (--limit, --page-token)
#   get          - Get full message (--id)
#   thread       - Get all messages in a thread (--id)
#   send         - Send email (--to, --subject, --text, --html, --cc, --bcc)
#   reply        - Reply to message (--id, --text, --html)
#   draft        - Create draft reply (--id, --text, --html) or new draft (--to, --subject, --text)
#   drafts list  - List drafts (--limit, --page-token)
#   drafts send  - Send an existing draft (--id)
#   delete-draft - Delete a draft (--id)
#   star         - Star message (--id)
#   unstar       - Unstar message (--id)
#   read         - Mark message as read (--id)
#   unread       - Mark message as unread (--id)
#   archive      - Archive message (--id)
#   trash        - Trash message (--id)
#   attachment   - Download attachment (--message-id, --attachment-id, --output)
#   labels       - List labels (--list) or create (--create NAME)
#   search       - Alias for list --q
#
# Environment:
#   - GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN (OAuth)
#   - Or GOOGLE_SERVICE_ACCOUNT_JSON / GOOGLE_CREDENTIALS_JSON
#
# Safety:
#   - send/reply/archive/trash are destructive; no --dry-run yet
#
# Notes:
#   - Outputs single-line JSON to stdout, logs to stderr

require 'json'
require 'optparse'
require 'base64'
require 'stringio'
require 'mail'
require_relative 'lib/google_client'

class GmailCLI
  METADATA_HEADERS = %w[From To Cc Subject Date Message-ID References].freeze

  def initialize
    @gmail = GoogleClient.gmail_service
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

  # ── Commands: listing ──

  def list(options)
    label = options[:label] || (options[:q] ? nil : 'INBOX')
    limit = options[:limit] || 20

    list_opts = { max_results: limit }
    list_opts[:label_ids] = [label] if label
    list_opts[:q] = options[:q] if options[:q]
    list_opts[:page_token] = options[:page_token] if options[:page_token]

    result = @gmail.list_user_messages('me', **list_opts)
    ids = (result.messages || []).map(&:id)
    messages = batch_fetch_metadata(ids)

    success(messages: messages, next_page_token: result.next_page_token)
  end

  def starred(options)
    limit = options[:limit] || 20

    list_opts = { label_ids: ['STARRED'], max_results: limit }
    list_opts[:page_token] = options[:page_token] if options[:page_token]

    result = @gmail.list_user_messages('me', **list_opts)
    ids = (result.messages || []).map(&:id)
    messages = batch_fetch_metadata(ids)

    success(messages: messages, next_page_token: result.next_page_token)
  end

  # ── Commands: reading ──

  def get(options)
    error('Missing --id', 'USAGE') unless options[:id]

    msg = @gmail.get_user_message('me', options[:id], format: 'full')
    success(extract_message(msg, full: true))
  end

  def thread(options)
    error('Missing --id', 'USAGE') unless options[:id]

    thread = @gmail.get_user_thread('me', options[:id], format: 'full')
    messages = (thread.messages || []).map { |msg| extract_message(msg, full: true) }

    success(thread_id: thread.id, message_count: messages.size, messages: messages)
  end

  def attachment(options)
    error('Missing --message-id', 'USAGE') unless options[:message_id]
    error('Missing --attachment-id', 'USAGE') unless options[:attachment_id]

    att = @gmail.get_user_message_attachment('me', options[:message_id], options[:attachment_id])

    if options[:output]
      data = decode_attachment(att.data)
      File.binwrite(options[:output], data)
      success(saved: options[:output], size: data.bytesize)
    else
      success(data: att.data, size: att.size)
    end
  end

  # ── Commands: sending ──

  def send_email(options)
    error('Missing --to', 'USAGE') unless options[:to]
    error('Missing --subject', 'USAGE') unless options[:subject]

    msg = build_raw_message(
      to: options[:to], subject: options[:subject],
      text: options[:text], html: options[:html],
      cc: options[:cc], bcc: options[:bcc]
    )

    result = @gmail.send_user_message('me', msg)
    success(id: result.id, thread: result.thread_id, labels: result.label_ids)
  end

  def reply(options)
    error('Missing --id', 'USAGE') unless options[:id]

    original = @gmail.get_user_message('me', options[:id], format: 'metadata',
                                       metadata_headers: %w[From To Subject Message-ID References])
    headers = original.payload&.headers || []
    reply_to = header(headers, 'Reply-To') || header(headers, 'From')
    subject = header(headers, 'Subject')
    subject = "Re: #{subject}" unless subject&.start_with?('Re:')
    message_id = header(headers, 'Message-ID')
    refs = [header(headers, 'References'), message_id].compact.join(' ')

    msg = build_raw_message(
      to: reply_to, subject: subject,
      text: options[:text], html: options[:html],
      in_reply_to: message_id, references: refs,
      thread_id: original.thread_id
    )

    result = @gmail.send_user_message('me', msg)
    success(id: result.id, thread: result.thread_id, labels: result.label_ids)
  end

  # ── Commands: drafts ──

  def draft(options)
    if options[:id]
      draft_reply(options)
    elsif options[:to] && options[:subject]
      draft_new(options)
    else
      error('Provide --id (reply draft) or --to and --subject (new draft)', 'USAGE')
    end
  end

  def drafts_list(options)
    limit = options[:limit] || 20
    list_opts = { max_results: limit }
    list_opts[:page_token] = options[:page_token] if options[:page_token]

    result = @gmail.list_user_drafts('me', **list_opts)

    drafts = (result.drafts || []).map do |d|
      full_draft = @gmail.get_user_draft('me', d.id, format: 'metadata')
      msg = extract_message(full_draft.message)
      { draft_id: full_draft.id, message: msg }
    end

    success(drafts: drafts, next_page_token: result.next_page_token)
  end

  def drafts_send(options)
    error('Missing --id (draft_id)', 'USAGE') unless options[:id]

    draft_obj = Google::Apis::GmailV1::Draft.new(id: options[:id])
    result = @gmail.send_user_draft('me', draft_obj)
    success(id: result.id, thread: result.thread_id, labels: result.label_ids)
  end

  def delete_draft(options)
    error('Missing --id (draft_id)', 'USAGE') unless options[:id]

    @gmail.delete_user_draft('me', options[:id])
    success(deleted: options[:id])
  end

  # ── Commands: label modifications ──

  def star(options)
    modify_labels(options, add: ['STARRED'])
  end

  def unstar(options)
    modify_labels(options, remove: ['STARRED'])
  end

  def mark_read(options)
    modify_labels(options, remove: ['UNREAD'])
  end

  def mark_unread(options)
    modify_labels(options, add: ['UNREAD'])
  end

  def archive(options)
    modify_labels(options, remove: ['INBOX'])
  end

  def trash(options)
    error('Missing --id', 'USAGE') unless options[:id]
    result = @gmail.trash_message('me', options[:id])
    success(id: result.id, labels: result.label_ids)
  end

  # ── Commands: labels ──

  def labels(options)
    if options[:create]
      label = Google::Apis::GmailV1::Label.new(name: options[:create])
      result = @gmail.create_user_label('me', label)
      success(id: result.id, name: result.name)
    else
      result = @gmail.list_user_labels('me')
      labels = (result.labels || []).map { |l| { id: l.id, name: l.name } }
      success(labels: labels)
    end
  end

  private

  # ── Message extraction ──

  def header(headers, name)
    h = headers&.find { |hdr| hdr.name.casecmp(name).zero? }
    h&.value
  end

  def extract_message(msg, full: false)
    headers = msg.payload&.headers || []
    result = {
      id: msg.id,
      thread: msg.thread_id,
      from: header(headers, 'From'),
      to: header(headers, 'To'),
      cc: header(headers, 'Cc'),
      subj: header(headers, 'Subject'),
      date: header(headers, 'Date'),
      snippet: msg.snippet,
      labels: msg.label_ids || []
    }

    if full
      result[:text] = extract_body(msg.payload, 'text/plain')
      result[:html] = extract_body(msg.payload, 'text/html')
      atts = extract_attachment_metadata(msg.payload)
      result[:attachments] = atts unless atts.empty?
    end

    result
  end

  def extract_body(payload, mime_type)
    return nil unless payload

    if payload.mime_type == mime_type && payload.body&.data
      return decode_body_data(payload.body.data)
    end

    (payload.parts || []).each do |part|
      body = extract_body(part, mime_type)
      return body if body
    end

    nil
  end

  def extract_attachment_metadata(payload, list = [])
    return list unless payload

    if payload.filename && !payload.filename.empty? && payload.body&.attachment_id
      list << {
        id: payload.body.attachment_id,
        filename: payload.filename,
        mime_type: payload.mime_type,
        size: payload.body.size
      }
    end

    (payload.parts || []).each { |part| extract_attachment_metadata(part, list) }
    list
  end

  # ── Decoding ──

  def decode_body_data(data)
    return nil unless data

    if data.length > 100 && data.match?(/\A[A-Za-z0-9+\/_-]*=*\z/)
      begin
        padded = data + '=' * ((4 - data.length % 4) % 4)
        decoded = Base64.urlsafe_decode64(padded)
        return decoded.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      rescue ArgumentError
        # Not valid base64, treat as plain text
      end
    end

    data.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
  end

  def decode_attachment(data)
    padded = data + '=' * ((4 - data.length % 4) % 4)
    Base64.urlsafe_decode64(padded)
  end

  # ── Batch fetching ──

  def batch_fetch_metadata(message_ids)
    return [] if message_ids.empty?

    messages = []
    message_ids.each_slice(100) do |batch_ids|
      @gmail.batch do |svc|
        batch_ids.each do |mid|
          svc.get_user_message('me', mid, format: 'metadata',
                               metadata_headers: METADATA_HEADERS) do |msg, err|
            messages << extract_message(msg) unless err
          end
        end
      end
    end
    messages
  end

  # ── Email building ──

  def build_raw_message(to:, subject:, text: nil, html: nil, cc: nil, bcc: nil,
                        in_reply_to: nil, references: nil, thread_id: nil)
    mail = build_mail(to: to, subject: subject, text: text, html: html,
                      cc: cc, bcc: bcc, in_reply_to: in_reply_to, references: references)

    raw = Base64.urlsafe_encode64(mail.to_s)
    msg = Google::Apis::GmailV1::Message.new(raw: raw)
    msg.thread_id = thread_id if thread_id
    msg
  end

  def build_mail(to:, subject:, text: nil, html: nil, cc: nil, bcc: nil,
                 in_reply_to: nil, references: nil)
    mail = Mail.new
    mail.to = to
    mail.subject = subject
    mail.cc = cc if cc
    mail.bcc = bcc if bcc
    mail['In-Reply-To'] = in_reply_to if in_reply_to
    mail['References'] = references if references

    if html && text
      mail.text_part = Mail::Part.new(body: text, content_type: 'text/plain; charset=UTF-8')
      mail.html_part = Mail::Part.new(body: html, content_type: 'text/html; charset=UTF-8')
    elsif html
      mail.body = html
      mail.content_type = 'text/html; charset=UTF-8'
    else
      mail.body = text || ''
      mail.content_type = 'text/plain; charset=UTF-8'
    end

    mail
  end

  # ── Label modification helper ──

  def modify_labels(options, add: nil, remove: nil)
    error('Missing --id', 'USAGE') unless options[:id]

    mod = Google::Apis::GmailV1::ModifyMessageRequest.new(
      add_label_ids: add,
      remove_label_ids: remove
    )
    result = @gmail.modify_message('me', options[:id], mod)
    success(id: result.id, labels: result.label_ids)
  end

  # ── Draft helpers ──

  def draft_reply(options)
    original = @gmail.get_user_message('me', options[:id], format: 'metadata',
                                       metadata_headers: %w[From To Subject Message-ID References])
    headers = original.payload&.headers || []
    reply_to = header(headers, 'Reply-To') || header(headers, 'From')
    subject = header(headers, 'Subject')
    subject = "Re: #{subject}" unless subject&.start_with?('Re:')
    message_id = header(headers, 'Message-ID')
    refs = [header(headers, 'References'), message_id].compact.join(' ')

    mail = build_mail(to: reply_to, subject: subject,
                      text: options[:text], html: options[:html],
                      in_reply_to: message_id, references: refs)

    create_draft(mail, thread_id: original.thread_id)
  end

  def draft_new(options)
    mail = build_mail(to: options[:to], subject: options[:subject],
                      text: options[:text], html: options[:html],
                      cc: options[:cc], bcc: options[:bcc])

    create_draft(mail)
  end

  def create_draft(mail, thread_id: nil)
    msg = Google::Apis::GmailV1::Message.new
    msg.thread_id = thread_id if thread_id
    draft_obj = Google::Apis::GmailV1::Draft.new(message: msg)

    result = @gmail.create_user_draft(
      'me', draft_obj,
      upload_source: StringIO.new(mail.to_s),
      content_type: 'message/rfc822'
    )

    success(
      draft_id: result.id,
      message_id: result.message&.id,
      thread: result.message&.thread_id
    )
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

begin
  cli = GmailCLI.new
  command = ARGV.shift

  case command
  when 'list', 'search'
    options = parse_options(
      [:label, '--label LABEL', nil],
      [:q, '--q QUERY', nil],
      [:limit, '--limit N', Integer],
      [:page_token, '--page-token TOKEN', nil]
    )
    cli.list(options)

  when 'starred'
    options = parse_options(
      [:limit, '--limit N', Integer],
      [:page_token, '--page-token TOKEN', nil]
    )
    cli.starred(options)

  when 'get'
    options = parse_options([:id, '--id ID', nil])
    cli.get(options)

  when 'thread'
    options = parse_options([:id, '--id ID', nil])
    cli.thread(options)

  when 'attachment'
    options = parse_options(
      [:message_id, '--message-id ID', nil],
      [:attachment_id, '--attachment-id ID', nil],
      [:output, '--output PATH', nil]
    )
    cli.attachment(options)

  when 'send'
    options = parse_options(
      [:to, '--to ADDR', nil],
      [:subject, '--subject SUBJ', nil],
      [:text, '--text TEXT', nil],
      [:html, '--html HTML', nil],
      [:cc, '--cc CC', nil],
      [:bcc, '--bcc BCC', nil]
    )
    cli.send_email(options)

  when 'reply'
    options = parse_options(
      [:id, '--id ID', nil],
      [:text, '--text TEXT', nil],
      [:html, '--html HTML', nil]
    )
    cli.reply(options)

  when 'draft'
    options = parse_options(
      [:id, '--id ID', nil],
      [:to, '--to ADDR', nil],
      [:subject, '--subject SUBJ', nil],
      [:text, '--text TEXT', nil],
      [:html, '--html HTML', nil],
      [:cc, '--cc CC', nil],
      [:bcc, '--bcc BCC', nil]
    )
    cli.draft(options)

  when 'drafts'
    subcommand = ARGV.shift
    case subcommand
    when 'list'
      options = parse_options(
        [:limit, '--limit N', Integer],
        [:page_token, '--page-token TOKEN', nil]
      )
      cli.drafts_list(options)
    when 'send'
      options = parse_options([:id, '--id ID', nil])
      cli.drafts_send(options)
    else
      cli.error("Unknown drafts subcommand: #{subcommand}", 'USAGE', 'Subcommands: list, send')
    end

  when 'delete-draft'
    options = parse_options([:id, '--id ID', nil])
    cli.delete_draft(options)

  when 'star'
    options = parse_options([:id, '--id ID', nil])
    cli.star(options)

  when 'unstar'
    options = parse_options([:id, '--id ID', nil])
    cli.unstar(options)

  when 'read'
    options = parse_options([:id, '--id ID', nil])
    cli.mark_read(options)

  when 'unread'
    options = parse_options([:id, '--id ID', nil])
    cli.mark_unread(options)

  when 'archive'
    options = parse_options([:id, '--id ID', nil])
    cli.archive(options)

  when 'trash'
    options = parse_options([:id, '--id ID', nil])
    cli.trash(options)

  when 'labels'
    options = parse_options(
      [:list, '--list', nil],
      [:create, '--create NAME', nil]
    )
    cli.labels(options)

  else
    cli.error("Unknown command: #{command}", 'USAGE',
              'Commands: list, starred, get, thread, send, reply, draft, drafts, ' \
              'delete-draft, star, unstar, read, unread, archive, trash, attachment, labels, search')
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
