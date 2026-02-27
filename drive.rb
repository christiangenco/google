#!/usr/bin/env ruby
# tools/google/drive.rb
#
# Purpose:
#   Google Drive CLI with file operations. Outputs compact JSON for LLM parsing.
#
# Usage:
#   bundle exec ruby tools/google/drive.rb <command> [options]
#
# Commands:
#   list        - List files (--q, --limit, --folder-id, --page-token)
#   search      - Full-text content search (--q, --limit, --page-token)
#   get         - Get file metadata (--id)
#   download    - Download file content (--id, --output, --export-format)
#   upload      - Upload file (--path, --name, --folder-id, --mime-type)
#   create      - Create empty file/doc (--name, --folder-id, --mime-type)
#   mkdir       - Create folder (--name, --folder-id)
#   update      - Update file metadata (--id, --name)
#   delete      - Delete file (--id)
#   copy        - Copy file (--id, --name, --folder-id)
#   move        - Move file to folder (--id, --folder-id)
#   share       - Share file (--id, --email, --anyone, --role)
#   unshare     - Remove sharing (--id, --permission-id)
#   permissions - List file permissions (--id)
#   folders     - List folders (--limit, --page-token)
#
# Environment:
#   - GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN (OAuth)
#   - Or GOOGLE_SERVICE_ACCOUNT_JSON / GOOGLE_CREDENTIALS_JSON
#
# Safety:
#   - upload/create/update/delete/share/unshare/move are destructive
#
# Notes:
#   - Outputs single-line JSON to stdout, logs to stderr
#   - list --q uses Drive metadata query syntax (name, mimeType, etc.)
#   - search --q searches inside file contents (fullText contains)

require 'json'
require 'optparse'
require_relative 'lib/google_client'

class DriveCLI
  COMMON_FIELDS = 'id,name,mimeType,size,createdTime,modifiedTime,parents,webViewLink,starred,trashed,owners,shared,sharingUser,description'.freeze

  EXPORT_FORMATS = {
    # Docs
    'text/plain' => 'txt',
    'application/pdf' => 'pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
    'text/html' => 'html',
    # Sheets
    'text/csv' => 'csv',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
    # Presentations
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' => 'pptx',
  }.freeze

  EXPORT_ALIASES = {
    'txt'  => 'text/plain',
    'text' => 'text/plain',
    'pdf'  => 'application/pdf',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'html' => 'text/html',
    'csv'  => 'text/csv',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  }.freeze

  DEFAULT_EXPORTS = {
    'application/vnd.google-apps.document'     => 'text/plain',
    'application/vnd.google-apps.spreadsheet'  => 'text/csv',
    'application/vnd.google-apps.presentation' => 'text/plain',
  }.freeze

  def initialize
    @drive = GoogleClient.drive_service
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

  def extract_file(file)
    result = {
      id: file.id,
      name: file.name,
      mime_type: file.mime_type,
      size: file.size,
      created: file.created_time&.to_s,
      modified: file.modified_time&.to_s,
      parents: file.parents,
      web_link: file.web_view_link,
      starred: file.starred,
      trashed: file.trashed,
      description: file.description,
      shared: file.shared,
    }

    if file.owners&.any?
      result[:owners] = file.owners.map { |o| o.email_address }
    end

    if file.sharing_user
      result[:sharing_user] = file.sharing_user.email_address
    end

    result.compact
  end

  def resolve_export_mime(format_str, file_mime_type)
    return DEFAULT_EXPORTS[file_mime_type] || 'text/plain' unless format_str

    # Try as alias first (e.g., "pdf", "docx")
    mime = EXPORT_ALIASES[format_str.downcase]
    return mime if mime

    # Try as raw mime type
    return format_str if EXPORT_FORMATS.key?(format_str)

    error("Unknown export format: #{format_str}", 'USAGE',
          "Supported: #{EXPORT_ALIASES.keys.join(', ')}")
  end

  # ── Commands ──

  def list(options)
    limit = options[:limit] || 20
    query_parts = []
    query_parts << options[:q] if options[:q]
    query_parts << "'#{options[:folder_id]}' in parents" if options[:folder_id]
    query = query_parts.empty? ? nil : query_parts.join(' and ')

    list_opts = {
      q: query,
      page_size: limit,
      fields: "nextPageToken,files(#{COMMON_FIELDS})"
    }
    list_opts[:page_token] = options[:page_token] if options[:page_token]

    result = @drive.list_files(**list_opts)
    files = (result.files || []).map { |f| extract_file(f) }
    data = { files: files }
    data[:next_page_token] = result.next_page_token if options[:page_token] && result.next_page_token
    data[:has_more] = true if !options[:page_token] && result.next_page_token
    success(data)
  end

  def search(options)
    error('Missing --q', 'USAGE') unless options[:q]

    limit = options[:limit] || 20
    query = "fullText contains '#{options[:q].gsub("'", "\\\\'")}'"

    list_opts = {
      q: query,
      page_size: limit,
      fields: "nextPageToken,files(#{COMMON_FIELDS})"
    }
    list_opts[:page_token] = options[:page_token] if options[:page_token]

    result = @drive.list_files(**list_opts)
    files = (result.files || []).map { |f| extract_file(f) }
    data = { files: files }
    data[:next_page_token] = result.next_page_token if options[:page_token] && result.next_page_token
    data[:has_more] = true if !options[:page_token] && result.next_page_token
    success(data)
  end

  def folders(options)
    limit = options[:limit] || 50

    list_opts = {
      q: "mimeType='application/vnd.google-apps.folder' and trashed=false",
      page_size: limit,
      fields: "nextPageToken,files(#{COMMON_FIELDS})"
    }
    list_opts[:page_token] = options[:page_token] if options[:page_token]

    result = @drive.list_files(**list_opts)
    folders = (result.files || []).map { |f| extract_file(f) }
    data = { folders: folders }
    data[:next_page_token] = result.next_page_token if options[:page_token] && result.next_page_token
    data[:has_more] = true if !options[:page_token] && result.next_page_token
    success(data)
  end

  def get(options)
    error('Missing --id', 'USAGE') unless options[:id]

    file = @drive.get_file(options[:id], fields: COMMON_FIELDS)
    success(extract_file(file))
  end

  def download(options)
    error('Missing --id', 'USAGE') unless options[:id]

    file = @drive.get_file(options[:id], fields: 'id,name,mimeType')

    if file.mime_type.start_with?('application/vnd.google-apps.')
      export_mime = resolve_export_mime(options[:export_format], file.mime_type)

      if options[:output]
        @drive.export_file(options[:id], export_mime, download_dest: options[:output])
        success(downloaded: true, path: options[:output], exported_as: export_mime)
      else
        content = @drive.export_file(options[:id], export_mime)
        success(content: content, exported_as: export_mime)
      end
    else
      if options[:output]
        @drive.get_file(options[:id], download_dest: options[:output])
        success(downloaded: true, path: options[:output])
      else
        content = StringIO.new
        @drive.get_file(options[:id], download_dest: content)
        success(content: content.string.force_encoding('UTF-8'))
      end
    end
  end

  def upload(options)
    error('Missing --path', 'USAGE') unless options[:path]
    error("File not found: #{options[:path]}", 'NOT_FOUND') unless File.exist?(options[:path])

    name = options[:name] || File.basename(options[:path])

    metadata = Google::Apis::DriveV3::File.new(name: name)
    metadata.parents = [options[:folder_id]] if options[:folder_id]

    result = @drive.create_file(
      metadata,
      upload_source: options[:path],
      content_type: options[:mime_type] || 'application/octet-stream',
      fields: COMMON_FIELDS
    )

    success(extract_file(result))
  end

  def create(options)
    error('Missing --name', 'USAGE') unless options[:name]

    metadata = Google::Apis::DriveV3::File.new(
      name: options[:name],
      mime_type: options[:mime_type] || 'application/vnd.google-apps.document'
    )
    metadata.parents = [options[:folder_id]] if options[:folder_id]

    result = @drive.create_file(metadata, fields: COMMON_FIELDS)
    success(extract_file(result))
  end

  def mkdir(options)
    error('Missing --name', 'USAGE') unless options[:name]

    metadata = Google::Apis::DriveV3::File.new(
      name: options[:name],
      mime_type: 'application/vnd.google-apps.folder'
    )
    metadata.parents = [options[:folder_id]] if options[:folder_id]

    result = @drive.create_file(metadata, fields: COMMON_FIELDS)
    success(extract_file(result))
  end

  def update(options)
    error('Missing --id', 'USAGE') unless options[:id]

    metadata = Google::Apis::DriveV3::File.new
    metadata.name = options[:name] if options[:name]
    metadata.description = options[:description] if options[:description]

    result = @drive.update_file(options[:id], metadata, fields: COMMON_FIELDS)
    success(extract_file(result))
  end

  def delete(options)
    error('Missing --id', 'USAGE') unless options[:id]

    @drive.delete_file(options[:id])
    success(deleted: true, id: options[:id])
  end

  def copy(options)
    error('Missing --id', 'USAGE') unless options[:id]

    metadata = Google::Apis::DriveV3::File.new
    metadata.name = options[:name] if options[:name]
    metadata.parents = [options[:folder_id]] if options[:folder_id]

    result = @drive.copy_file(options[:id], metadata, fields: COMMON_FIELDS)
    success(extract_file(result))
  end

  def move(options)
    error('Missing --id', 'USAGE') unless options[:id]
    error('Missing --folder-id', 'USAGE') unless options[:folder_id]

    # Get current parents
    file = @drive.get_file(options[:id], fields: 'id,parents')
    previous_parents = (file.parents || []).join(',')

    result = @drive.update_file(
      options[:id],
      Google::Apis::DriveV3::File.new,
      add_parents: options[:folder_id],
      remove_parents: previous_parents,
      fields: COMMON_FIELDS
    )
    success(extract_file(result))
  end

  def share(options)
    error('Missing --id', 'USAGE') unless options[:id]

    role = options[:role] || 'reader'

    if options[:anyone]
      permission = Google::Apis::DriveV3::Permission.new(
        type: 'anyone',
        role: role
      )
    elsif options[:email]
      permission = Google::Apis::DriveV3::Permission.new(
        type: 'user',
        role: role,
        email_address: options[:email]
      )
    else
      error('Provide --email or --anyone', 'USAGE')
    end

    result = @drive.create_permission(options[:id], permission, fields: 'id,type,role,emailAddress')
    success(
      permission_id: result.id,
      type: result.type,
      role: result.role,
      email: result.email_address
    )
  end

  def unshare(options)
    error('Missing --id', 'USAGE') unless options[:id]
    error('Missing --permission-id', 'USAGE') unless options[:permission_id]

    @drive.delete_permission(options[:id], options[:permission_id])
    success(deleted: true, file_id: options[:id], permission_id: options[:permission_id])
  end

  def permissions(options)
    error('Missing --id', 'USAGE') unless options[:id]

    result = @drive.list_permissions(options[:id], fields: 'permissions(id,type,role,emailAddress,displayName)')
    perms = (result.permissions || []).map do |p|
      {
        id: p.id,
        type: p.type,
        role: p.role,
        email: p.email_address,
        name: p.display_name,
      }.compact
    end
    success(permissions: perms)
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

ID_OPT = [:id, '--id ID', nil].freeze
FOLDER_ID_OPT = [:folder_id, '--folder-id ID', nil].freeze
LIMIT_OPT = [:limit, '--limit N', Integer].freeze
PAGE_TOKEN_OPT = [:page_token, '--page-token TOKEN', nil].freeze
NAME_OPT = [:name, '--name NAME', nil].freeze

def check_help(usage_text)
  if ARGV.include?('--help') || ARGV.include?('-h')
    puts usage_text
    exit 0
  end
end

begin
  cli = DriveCLI.new
  command = ARGV.shift

  case command
  when 'list'
    check_help(<<~HELP)
      Usage: google-cli drive list [options]
        List files (uses Drive metadata query syntax)
        --q QUERY            Drive query (e.g., "name contains 'report'")
        --limit N            Max results (default: 20)
        --folder-id ID       List files in folder
        --page-token TOKEN   Pagination token
    HELP
    options = parse_options(
      [:q, '--q QUERY', nil],
      LIMIT_OPT,
      FOLDER_ID_OPT,
      PAGE_TOKEN_OPT
    )
    cli.list(options)

  when 'search'
    check_help(<<~HELP)
      Usage: google-cli drive search --q QUERY [options]
        Full-text content search inside files
        --q QUERY            Search query (required)
        --limit N            Max results (default: 20)
        --page-token TOKEN   Pagination token
    HELP
    options = parse_options(
      [:q, '--q QUERY', nil],
      LIMIT_OPT,
      PAGE_TOKEN_OPT
    )
    cli.search(options)

  when 'folders'
    check_help(<<~HELP)
      Usage: google-cli drive folders [options]
        List folders
        --limit N            Max results (default: 50)
        --page-token TOKEN   Pagination token
    HELP
    options = parse_options(
      LIMIT_OPT,
      PAGE_TOKEN_OPT
    )
    cli.folders(options)

  when 'get'
    check_help("Usage: google-cli drive get --id FILE_ID\n  Get file metadata\n  --id ID    File ID (required)")
    options = parse_options(ID_OPT)
    cli.get(options)

  when 'download'
    check_help(<<~HELP)
      Usage: google-cli drive download --id FILE_ID [options]
        Download file content
        --id ID                File ID (required)
        --output PATH          Save to file path
        --export-format FMT    Export format for Google Docs (txt, pdf, docx, html, csv, xlsx, pptx)
    HELP
    options = parse_options(
      ID_OPT,
      [:output, '--output PATH', nil],
      [:export_format, '--export-format FMT', nil]
    )
    cli.download(options)

  when 'upload'
    check_help(<<~HELP)
      Usage: google-cli drive upload --path FILE [options]
        Upload a file
        --path PATH          Local file path (required)
        --name NAME          File name in Drive (default: basename)
        --folder-id ID       Upload to folder
        --mime-type TYPE     MIME type
    HELP
    options = parse_options(
      [:path, '--path PATH', nil],
      NAME_OPT,
      FOLDER_ID_OPT,
      [:mime_type, '--mime-type TYPE', nil]
    )
    cli.upload(options)

  when 'create'
    check_help(<<~HELP)
      Usage: google-cli drive create --name NAME [options]
        Create an empty file/doc
        --name NAME          File name (required)
        --folder-id ID       Parent folder
        --mime-type TYPE     MIME type (default: Google Doc)
    HELP
    options = parse_options(
      NAME_OPT,
      FOLDER_ID_OPT,
      [:mime_type, '--mime-type TYPE', nil]
    )
    cli.create(options)

  when 'mkdir'
    check_help(<<~HELP)
      Usage: google-cli drive mkdir --name NAME [--folder-id ID]
        Create a folder
        --name NAME          Folder name (required)
        --folder-id ID       Parent folder
    HELP
    options = parse_options(
      NAME_OPT,
      FOLDER_ID_OPT
    )
    cli.mkdir(options)

  when 'update'
    check_help(<<~HELP)
      Usage: google-cli drive update --id FILE_ID [options]
        Update file metadata
        --id ID              File ID (required)
        --name NAME          New file name
        --description DESC   New description
    HELP
    options = parse_options(
      ID_OPT,
      NAME_OPT,
      [:description, '--description DESC', nil]
    )
    cli.update(options)

  when 'delete'
    check_help("Usage: google-cli drive delete --id FILE_ID\n  Delete a file\n  --id ID    File ID (required)")
    options = parse_options(ID_OPT)
    cli.delete(options)

  when 'copy'
    check_help(<<~HELP)
      Usage: google-cli drive copy --id FILE_ID [options]
        Copy a file
        --id ID              File ID (required)
        --name NAME          New file name
        --folder-id ID       Destination folder
    HELP
    options = parse_options(
      ID_OPT,
      NAME_OPT,
      FOLDER_ID_OPT
    )
    cli.copy(options)

  when 'move'
    check_help(<<~HELP)
      Usage: google-cli drive move --id FILE_ID --folder-id FOLDER_ID
        Move a file to a different folder
        --id ID              File ID (required)
        --folder-id ID       Destination folder (required)
    HELP
    options = parse_options(
      ID_OPT,
      FOLDER_ID_OPT
    )
    cli.move(options)

  when 'share'
    check_help(<<~HELP)
      Usage: google-cli drive share --id FILE_ID [--email ADDR | --anyone] [options]
        Share a file
        --id ID              File ID (required)
        --email ADDR         Share with specific user
        --anyone             Share with anyone (public link)
        --role ROLE          Permission role (reader, writer, commenter; default: reader)
    HELP
    options = parse_options(
      ID_OPT,
      [:email, '--email ADDR', nil],
      [:anyone, '--anyone', nil],
      [:role, '--role ROLE', nil]
    )
    cli.share(options)

  when 'unshare'
    check_help(<<~HELP)
      Usage: google-cli drive unshare --id FILE_ID --permission-id PID
        Remove a sharing permission
        --id ID              File ID (required)
        --permission-id PID  Permission ID (required)
    HELP
    options = parse_options(
      ID_OPT,
      [:permission_id, '--permission-id PID', nil]
    )
    cli.unshare(options)

  when 'permissions'
    check_help("Usage: google-cli drive permissions --id FILE_ID\n  List file permissions\n  --id ID    File ID (required)")
    options = parse_options(ID_OPT)
    cli.permissions(options)

  when '--help', '-h', 'help', nil
    puts <<~HELP
      google-cli drive - Google Drive CLI

      Commands:
        list          List files (--q, --limit, --folder-id)
        search        Full-text content search (--q)
        folders       List folders (--limit)
        get           Get file metadata (--id)
        download      Download file (--id, --output, --export-format)
        upload        Upload file (--path, --name, --folder-id)
        create        Create empty file/doc (--name, --mime-type)
        mkdir         Create folder (--name)
        update        Update metadata (--id, --name)
        delete        Delete file (--id)
        copy          Copy file (--id, --name, --folder-id)
        move          Move file (--id, --folder-id)
        share         Share file (--id, --email/--anyone, --role)
        unshare       Remove sharing (--id, --permission-id)
        permissions   List permissions (--id)

      Run: google-cli drive <command> --help for details
    HELP
    exit 0

  else
    cli.error("Unknown command: #{command}", 'USAGE',
      'Commands: list, search, get, download, upload, create, mkdir, update, delete, copy, move, share, unshare, permissions, folders')
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
