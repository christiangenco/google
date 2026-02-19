require 'dotenv/load'
require 'googleauth'
require 'google/apis/gmail_v1'
require 'google/apis/calendar_v3'
require 'google/apis/tasks_v1'
require 'google/apis/drive_v3'
require 'google/apis/people_v1'
require 'google/apis/forms_v1'
require 'stringio'

module GoogleClient
  GMAIL_SCOPES = [
    'https://www.googleapis.com/auth/gmail.modify',
    'https://www.googleapis.com/auth/gmail.send'
  ].freeze

  CALENDAR_SCOPES = [
    'https://www.googleapis.com/auth/calendar'
  ].freeze

  TASKS_SCOPES = [
    'https://www.googleapis.com/auth/tasks'
  ].freeze

  DRIVE_SCOPES = [
    'https://www.googleapis.com/auth/drive'
  ].freeze

  PEOPLE_SCOPES = [
    'https://www.googleapis.com/auth/contacts.readonly'
  ].freeze

  FORMS_SCOPES = [
    'https://www.googleapis.com/auth/forms.body'
  ].freeze

  def self.gmail_service
    service = Google::Apis::GmailV1::GmailService.new
    service.authorization = credentials(GMAIL_SCOPES)
    service
  end

  def self.calendar_service
    service = Google::Apis::CalendarV3::CalendarService.new
    service.authorization = credentials(CALENDAR_SCOPES)
    service
  end

  def self.tasks_service
    service = Google::Apis::TasksV1::TasksService.new
    service.authorization = credentials(TASKS_SCOPES)
    service
  end

  def self.drive_service
    service = Google::Apis::DriveV3::DriveService.new
    service.authorization = credentials(DRIVE_SCOPES)
    service
  end

  def self.people_service
    service = Google::Apis::PeopleV1::PeopleServiceService.new
    service.authorization = credentials(PEOPLE_SCOPES)
    service
  end

  def self.forms_service
    service = Google::Apis::FormsV1::FormsService.new
    service.authorization = credentials(FORMS_SCOPES)
    service
  end

  def self.credentials(scopes)
    client_id     = ENV['GOOGLE_CLIENT_ID']     || ENV['CLIENT_ID']
    client_secret = ENV['GOOGLE_CLIENT_SECRET'] || ENV['CLIENT_SECRET']
    refresh_token = ENV['GOOGLE_REFRESH_TOKEN'] || ENV['REFRESH_TOKEN']
    sa_json       = ENV['GOOGLE_SERVICE_ACCOUNT_JSON'] || ENV['SERVICE_ACCOUNT_JSON']
    oauth_json    = ENV['GOOGLE_CREDENTIALS_JSON']     || ENV['CREDENTIALS_JSON']

    if sa_json
      Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(sa_json),
        scope: scopes
      )
    elsif oauth_json
      Google::Auth::UserRefreshCredentials.make_creds(
        json_key_io: StringIO.new(oauth_json),
        scope: scopes
      )
    elsif client_id && client_secret && refresh_token
      Google::Auth::UserRefreshCredentials.new(
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token,
        scope: scopes
      )
    else
      raise 'No valid Google credentials found in env'
    end
  end
end
