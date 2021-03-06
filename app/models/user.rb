#   Copyright (c) 2010, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

require File.join(Rails.root, 'lib/diaspora/user')
require File.join(Rails.root, 'lib/salmon/salmon')

class InvitedUserValidator < ActiveModel::Validator
  def validate(document)
    unless document.invitation_token
      unless document.person
        document.errors[:base] << "Unless you are being invited, you must have a person"
      end
    end
  end
end

class User
  include MongoMapper::Document
  include Diaspora::UserModules
  include Encryptor::Private

  plugin MongoMapper::Devise

  QUEUE = MessageHandler.new

  devise :invitable, :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable

  key :username
  key :serialized_private_key, String
  key :invites, Integer, :default => 5
  key :invitation_token, String
  key :invitation_sent_at, DateTime
  key :inviter_ids, Array
  key :friend_ids, Array
  key :pending_request_ids, Array
  key :visible_post_ids, Array
  key :visible_person_ids, Array

  key :invite_messages, Hash

  before_validation :strip_username, :on => :create
  validates_presence_of :username
  validates_uniqueness_of :username, :case_sensitive => false
  validates_format_of :username, :without => /\s/

  validates_with InvitedUserValidator

  one :person, :class_name => 'Person', :foreign_key => :owner_id

  many :inviters, :in => :inviter_ids, :class_name => 'User'
  many :friends, :in => :friend_ids, :class_name => 'Person'
  many :visible_people, :in => :visible_person_ids, :class_name => 'Person' # One of these needs to go
  many :pending_requests, :in => :pending_request_ids, :class_name => 'Request'
  many :raw_visible_posts, :in => :visible_post_ids, :class_name => 'Post'
  many :aspects, :class_name => 'Aspect', :dependent => :destroy

  after_create :seed_aspects

  before_destroy :unfriend_everyone, :remove_person, :remove_all_aspects

  def strip_username
    if username.present?
      username.strip!
    end
  end

  def self.find_for_authentication(conditions={})
    if conditions[:username] =~ /^([\w\.%\+\-]+)@([\w\-]+\.)+([\w]{2,})$/i # email regex
      conditions[:email] = conditions.delete(:username)
    end
    super
  end

  ######## Making things work ########
  key :email, String

  def method_missing(method, *args)
    self.person.send(method, *args)
  end

  def real_name
    "#{person.profile.first_name.to_s} #{person.profile.last_name.to_s}"
  end

  ######### Aspects ######################
  def aspect(opts = {})
    opts[:user] = self
    Aspect.create(opts)
  end

  def drop_aspect(aspect)
    if aspect.people.size == 0
      aspect.destroy
    else
      raise "Aspect not empty"
    end
  end

  def move_friend(opts = {})
    return true if opts[:to] == opts[:from]
    friend = Person.first(:_id => opts[:friend_id])
    if self.friend_ids.include?(friend.id)
      from_aspect = self.aspect_by_id(opts[:from])
      to_aspect = self.aspect_by_id(opts[:to])
      if from_aspect && to_aspect
        posts_to_move = from_aspect.posts.find_all_by_person_id(friend.id)
        to_aspect.people << friend
        to_aspect.posts << posts_to_move
        from_aspect.person_ids.delete(friend.id.to_id)
        posts_to_move.each { |x| from_aspect.post_ids.delete(x.id) }
        from_aspect.save
        to_aspect.save
        return true
      end
    end
    false
  end

  ######## Posting ########
  def post(class_name, options = {})
    if class_name == :photo
      raise ArgumentError.new("No album_id given") unless options[:album_id]
      aspect_ids = aspects_with_post(options[:album_id])
      aspect_ids.map! { |aspect| aspect.id }
    else
      aspect_ids = options.delete(:to)
    end

    aspect_ids = validate_aspect_permissions(aspect_ids)

    intitial_post(class_name, aspect_ids, options)
  end

  def post_to_message_fb(message, access_token)
    id = 'me'
    type = 'feed'
    Rails.logger.info("Sending a message: #{message} to Facebook")
    EventMachine::HttpRequest.new("https://graph.facebook.com/me/feed?message=#{message}&access_token=#{access_token}").post
  end

  def intitial_post(class_name, aspect_ids, options = {})
    post = build_post(class_name, options)
    post.socket_to_uid(id, :aspect_ids => aspect_ids) if post.respond_to?(:socket_to_uid)
    push_to_aspects(post, aspect_ids)
    post
  end

  def update_post(post, post_hash = {})
    if self.owns? post
      post.update_attributes(post_hash)
    end
  end

  def validate_aspect_permissions(aspect_ids)
    if aspect_ids == "all"
      return aspect_ids
    end

    aspect_ids = [aspect_ids.to_s] unless aspect_ids.is_a? Array

    if aspect_ids.nil? || aspect_ids.empty?
      raise ArgumentError.new("You must post to someone.")
    end

    aspect_ids.each do |aspect_id|
      unless self.aspects.find(aspect_id)
        raise ArgumentError.new("Cannot post to an aspect you do not own.")
      end
    end

    aspect_ids
  end

  def build_post(class_name, options = {})
    options[:person] = self.person
    model_class = class_name.to_s.camelize.constantize
    post = model_class.instantiate(options)
    post.save
    self.raw_visible_posts << post
    self.save
    post
  end

  def push_to_aspects(post, aspect_ids)
    if aspect_ids == :all || aspect_ids == "all"
      aspects = self.aspects
    elsif aspect_ids.is_a?(Array) && aspect_ids.first.class == Aspect
      aspects = aspect_ids
    else
      aspects = self.aspects.find_all_by_id(aspect_ids)
    end
    #send to the aspects
    target_people = []

    aspects.each { |aspect|
      aspect.posts << post
      aspect.save
      target_people = target_people | aspect.people
    }

    push_to_hub(post) if post.respond_to?(:public) && post.public

    push_to_people(post, target_people)
  end

  def push_to_people(post, people)
    salmon = salmon(post)
    people.each { |person|
      xml = salmon.xml_for person
      push_to_person(person, xml)
    }
  end

  def push_to_person(person, xml)
    Rails.logger.debug("#{self.real_name} is adding xml to message queue to #{person.receive_url}")
    QUEUE.add_post_request(person.receive_url, xml)
    QUEUE.process
  end

  def push_to_hub(post)
    Rails.logger.debug("Pushing update to pubsub server #{APP_CONFIG[:pubsub_server]} with url #{self.public_url}")
    QUEUE.add_hub_notification(APP_CONFIG[:pubsub_server], self.public_url)
  end

  def salmon(post)
    created_salmon = Salmon::SalmonSlap.create(self, post.to_diaspora_xml)
    created_salmon
  end

  ######## Commenting  ########
  def comment(text, options = {})
    comment = build_comment(text, options)
    if comment
      dispatch_comment comment
      comment.socket_to_uid id
    end
    comment
  end

  def build_comment(text, options = {})
    raise "must comment on something!" unless options[:on]
    comment = Comment.new(:person_id => self.person.id, :text => text, :post => options[:on])
    comment.creator_signature = comment.sign_with_key(encryption_key)
    if comment.save
      comment
    else
      Rails.logger.warn "this failed to save: #{comment.inspect}"
      false
    end
  end

  def dispatch_comment(comment)
    if owns? comment.post
      comment.post_creator_signature = comment.sign_with_key(encryption_key)
      comment.save
      push_to_people comment, people_in_aspects(aspects_with_post(comment.post.id))
    elsif owns? comment
      comment.save
      push_to_people comment, [comment.post.person]
    end
  end

  ######### Posts and Such ###############
  def retract(post)
    aspect_ids = aspects_with_post(post.id)
    aspect_ids.map! { |aspect| aspect.id.to_s }

    post.unsocket_from_uid(self.id, :aspect_ids => aspect_ids) if post.respond_to? :unsocket_from_uid
    retraction = Retraction.for(post)
    push_to_people retraction, people_in_aspects(aspects_with_post(post.id))
    retraction
  end

  ########### Profile ######################
  def update_profile(params)
    if self.person.update_attributes(params)
      push_to_aspects profile, :all
      true
    else
      false
    end
  end

  ###Invitations############
  def invite_user(opts = {})
    if self.invites > 0

      aspect_id = opts.delete(:aspect_id)
      if aspect_id == nil
        raise "Must invite into aspect"
      end
      aspect_object = self.aspects.find_by_id(aspect_id)
      if !(aspect_object)
        raise "Must invite to your aspect"
      else
        u = User.find_by_email(opts[:email])
        if u.nil?  
        elsif friends.include?(u.person)
          raise "You are already friends with this person"          
        elsif not u.invited?
          self.send_friend_request_to(u.person, aspect_object)
          return
        elsif u.invited? && u.inviters.include?(self)
          raise "You already invited this person"          
        end
      end
      request = Request.instantiate(
        :to => "http://local_request.example.com",
        :from => self.person,
        :into => aspect_id
      )

      invited_user = User.invite!(:email => opts[:email], :request => request, :inviter => self, :invite_message => opts[:invite_message])

      self.invites = self.invites - 1
      self.pending_requests << request
      request.save
      self.save!
      invited_user
    else
      raise "You have no invites"
    end
  end

  def self.invite!(attributes={})
    inviter = attributes.delete(:inviter)
    request = attributes.delete(:request)

    invitable = find_or_initialize_with_error_by(:email, attributes.delete(:email))
    invitable.attributes = attributes
    if invitable.inviters.include?(inviter)
      raise "You already invited this person"
    else
      invitable.pending_requests << request
      invitable.inviters << inviter
      message = attributes.delete(:invite_message)
      if message
        invitable.invite_messages[inviter.id.to_s] = message
      end
    end

    if invitable.new_record?
      invitable.errors.clear if invitable.email.try(:match, Devise.email_regexp)
    else
      invitable.errors.add(:email, :taken) unless invitable.invited?
    end

    invitable.invite! if invitable.errors.empty?
    invitable
  end

  def accept_invitation!(opts = {})
    if self.invited?
      self.username              = opts[:username]
      self.password              = opts[:password]
      self.password_confirmation = opts[:password_confirmation]
      opts[:person][:diaspora_handle] = "#{opts[:username]}@#{APP_CONFIG[:terse_pod_url]}"
      opts[:person][:url] = APP_CONFIG[:pod_url]

      opts[:serialized_private_key] = User.generate_key
      self.serialized_private_key =  opts[:serialized_private_key]
      opts[:person][:serialized_public_key] = opts[:serialized_private_key].public_key

      person_hash = opts.delete(:person)
      self.person = Person.create(person_hash)
      self.person.save
      self.invitation_token = nil
      self.save
      self
    end
  end

  ###Helpers############
  def self.instantiate!(opts = {})
    opts[:person][:diaspora_handle] = "#{opts[:username]}@#{APP_CONFIG[:terse_pod_url]}"
    opts[:person][:url] = APP_CONFIG[:pod_url]

    opts[:serialized_private_key] = generate_key
    opts[:person][:serialized_public_key] = opts[:serialized_private_key].public_key
    User.create(opts)
  end

  def seed_aspects
    aspect(:name => "Family")
    aspect(:name => "Work")
  end

  def diaspora_handle
    "#{self.username}@#{APP_CONFIG[:terse_pod_url]}".downcase
  end

  def as_json(opts={})
    {
      :user => {
        :posts            => self.raw_visible_posts.each { |post| post.as_json },
        :friends          => self.friends.each { |friend| friend.as_json },
        :aspects           => self.aspects.each { |aspect| aspect.as_json },
        :pending_requests => self.pending_requests.each { |request| request.as_json },
      }
    }
  end


  def self.generate_key
    OpenSSL::PKey::RSA::generate 4096
  end

  def encryption_key
    OpenSSL::PKey::RSA.new(serialized_private_key)
  end

  protected

  def remove_person
    self.person.destroy
  end

  def unfriend_everyone
    friends.each { |friend|
      if friend.owner?
        friend.owner.unfriended_by self.person
      else
        self.unfriend friend
      end
    }
  end
  
  def remove_all_aspects
    aspects.destroy_all
  end
end
