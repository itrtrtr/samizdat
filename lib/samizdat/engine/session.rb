# Samizdat session management
#
#   Copyright (c) 2002-2011  Dmitry Borodaenko <angdraug@debian.org>
#
#   This program is free software.
#   You can distribute/modify this program under the terms of
#   the GNU General Public License version 3 or later.
#
# vim: et sw=2 sts=2 ts=8 tw=0

require 'samizdat'

# session management
#
class Session
  include SiteHelper

  # cookie is a hex digest between 128 and 2048 bits long
  COOKIE_PATTERN = Regexp.new(/\A[[:alnum:]]{32,512}\z/).freeze

  def Session.cache_key(cookie)
    'session/' + cookie
  end

  # set _@login_ and _@full_name_ to 'guest'
  #
  def reset_to_guest
    @cookie = nil
    @member = nil
    copy_from_member_object
  end

  # Usage:
  #
  #   Session.new(request.cookie('session'))
  #
  def initialize(site, cookie)
    @site = site

    if cookie and cookie =~ COOKIE_PATTERN
      @cookie = cookie

      db.transaction do
        if m = db[:member].filter(:session => @cookie).select(:id, :login_time).first
          @member = m[:id]
          @login_time = m[:login_time]
          fresh!
        end
      end
    end

    if @member
      copy_from_member_object
    else
      reset_to_guest
    end
  end

  attr_reader :member, :login, :full_name

  # Start new session on login. Check _password_ if it is provided.
  #
  # Return cookie value on success, +nil+ on failure.
  #
  def start!(login, password)
    db.transaction do
      m = db[:member].filter(:login => login).select(:id, :password).first
      if m and m[:password].nil?
        report_blocked_account(login, m[:id])
      elsif m.nil? or (password and not Password.check(password, m[:password]))
        return nil
      end

      @cookie = random_digest(m[:id])
      db[:member][:id => m[:id]] = {
        :login_time => CURRENT_TIMESTAMP,
        :last_time => CURRENT_TIMESTAMP,
        :session => @cookie
      }

      @member = m[:id]
      @login_time = Time.now
      copy_from_member_object
      return @cookie
    end
  end

  # true if moderator priviledges are available to this member
  #
  def moderator?
    @moderator
  end

  # erase session from database, remove the session cookie
  #
  def clear!
    if @member
      db[:member][:id => @member] = {:session => nil}
    end
    if @cookie
      cache.delete(Session.cache_key(@cookie))
    end
    reset_to_guest
  end

  # check if session is still fresh, clear it if it's not
  #
  def fresh!
    if @login_time and @login_time.to_time < Time.now - config['timeout']['login']
      clear!   # remove stale session
      false
    else
      true
    end
  end

  private

  def copy_from_member_object(member = Member.cached(site, @member))
    @login = member.login
    @full_name = member.full_name
    @moderator = member.allowed_to?('moderate')
  end

  def report_blocked_account(login, id)
    prefs = Preferences.new(site, login)

    message =
      if prefs['password'] and prefs['email']
        _('Thank you for signing up for an account. A confirmation e-mail message was sent to your e-mail address. Follow the instructions in the e-mail to complete your account setup. You can then use your account to more conveniently post on this site.')

      elsif prefs['password']
        sprintf(
          _('Your account is <a href="%s">blocked by moderators</a>.'),
          'moderation/' + id.to_s)

      else
        _('Your account is broken: it has no assigned password.') +
          if site.email_enabled?
            ' ' + sprintf(
              _('Request <a href="%s">password recovery</a> to generate new password.'),
              'member/recover')
          else
            ''
          end
      end

    raise AccountBlockedError, message
  end
end
