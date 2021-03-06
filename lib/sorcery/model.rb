module Sorcery
  # This module handles all plugin operations which are related to the Model layer in the MVC pattern.
  # It should be included into the ORM base class.
  # In the case of Rails this is usually ActiveRecord (actually, in that case, the plugin does this automatically).
  #
  # When included it defines a single method: 'activate_sorcery!' which when called adds the other capabilities 
  # to the class.
  # This method is also the place to configure the plugin in the Model layer.
  module Model
    def self.included(klass)
      klass.class_eval do
        class << self
          def authenticates_with_sorcery!
            @sorcery_config = Config.new
            self.class_eval do
              extend ClassMethods # included here, before submodules, so they can be overriden by them.
              include InstanceMethods
            end
            
            include_required_submodules!

            # This runs the options block set in the initializer on the model class.
            ::Sorcery::Controller::Config.user_config.tap{|blk| blk.call(@sorcery_config) if blk}
            
            init_mongoid_support! if defined?(Mongoid) and self.ancestors.include?(Mongoid::Document)

            init_orm_hooks!
            
            @sorcery_config.after_config << :add_config_inheritance if @sorcery_config.subclasses_inherit_config
            @sorcery_config.after_config.each { |c| send(c) }
          end
          
          protected
          
          # includes required submodules into the model class, 
          # which usually is called User.
          def include_required_submodules!
            self.class_eval do
              @sorcery_config.submodules = ::Sorcery::Controller::Config.submodules
              @sorcery_config.submodules.each do |mod|
                begin
                  include Submodules.const_get(mod.to_s.split("_").map {|p| p.capitalize}.join("")) 
                rescue NameError
                  # don't stop on a missing submodule. Needed because some submodules are only defined 
                  # in the controller side.
                end
              end
            end
          end
          
          # defines mongoid fields on the model class,
          # using 1.8.x hash syntax to perserve compatibility.
          def init_mongoid_support!
            self.class_eval do
              field sorcery_config.username_attribute_name,         :type => String
              field sorcery_config.email_attribute_name,            :type => String unless sorcery_config.username_attribute_name == sorcery_config.email_attribute_name
              field sorcery_config.crypted_password_attribute_name, :type => String
              field sorcery_config.salt_attribute_name,             :type => String
            end
          end
          
          # add virtual password accessor and ORM callbacks.
          def init_orm_hooks!
            self.class_eval do
              attr_accessor @sorcery_config.password_attribute_name
              attr_protected @sorcery_config.crypted_password_attribute_name, @sorcery_config.salt_attribute_name
              before_save :encrypt_password, :if => Proc.new { |record| record.send(sorcery_config.password_attribute_name).present? }
              after_save :clear_virtual_password, :if => Proc.new { |record| record.send(sorcery_config.password_attribute_name).present? }
            end
          end
        end
      end
    end
    
    module ClassMethods
      # Returns the class instance variable for configuration, when called by the class itself.
      def sorcery_config
        @sorcery_config
      end
      
      # The default authentication method.
      # Takes a username and password,
      # Finds the user by the username and compares the user's password to the one supplied to the method.
      # returns the user if success, nil otherwise.
      def authenticate(*credentials)
        raise ArgumentError, "at least 2 arguments required" if credentials.size < 2
        user = find_by_credentials(credentials)
        _salt = user.send(@sorcery_config.salt_attribute_name) if user && !@sorcery_config.salt_attribute_name.nil? && !@sorcery_config.encryption_provider.nil?
        user if user && @sorcery_config.before_authenticate.all? {|c| user.send(c)} && credentials_match?(user.send(@sorcery_config.crypted_password_attribute_name),credentials[1],_salt)
      end
      
      # encrypt tokens using current encryption_provider.
      def encrypt(*tokens)
        return tokens.first if @sorcery_config.encryption_provider.nil?
        
        @sorcery_config.encryption_provider.stretches = @sorcery_config.stretches if @sorcery_config.encryption_provider.respond_to?(:stretches) && @sorcery_config.stretches
        @sorcery_config.encryption_provider.join_token = @sorcery_config.salt_join_token if @sorcery_config.encryption_provider.respond_to?(:join_token) && @sorcery_config.salt_join_token
        CryptoProviders::AES256.key = @sorcery_config.encryption_key if @sorcery_config.encryption_algorithm == :aes256
        @sorcery_config.encryption_provider.encrypt(*tokens)
      end
      
      protected
      
      # Calls the configured encryption provider to compare the supplied password with the encrypted one.
      def credentials_match?(crypted, *tokens)
        return crypted == tokens.join if @sorcery_config.encryption_provider.nil?
        @sorcery_config.encryption_provider.matches?(crypted, *tokens)
      end
      
      def add_config_inheritance
        self.class_eval do
          def self.inherited(subclass)
            subclass.class_eval do
              class << self
                attr_accessor :sorcery_config
              end
            end
            subclass.sorcery_config = sorcery_config
            super
          end
        end
      end
      
    end
    
    module InstanceMethods
      # Returns the class instance variable for configuration, when called by an instance.
      def sorcery_config
        self.class.sorcery_config
      end
      
      # identifies whether this user is regular, i.e. we hold his credentials in our db,
      # or that he is external, and his credentials are saved elsewhere (twitter/facebook etc.).
      def external?
        send(sorcery_config.crypted_password_attribute_name).nil?
      end
      
      protected
      
      # creates new salt and saves it.
      # encrypts password with salt and saves it.
      def encrypt_password
        config = sorcery_config
        self.send(:"#{config.salt_attribute_name}=", new_salt = generate_random_token) if !config.salt_attribute_name.nil?
        self.send(:"#{config.crypted_password_attribute_name}=", self.class.encrypt(self.send(config.password_attribute_name),new_salt))
      end

      def clear_virtual_password
        config = sorcery_config
        self.send(:"#{config.password_attribute_name}=", nil)
      end
      
      # calls the requested email method on the configured mailer
      # supports both the ActionMailer 3 way of calling, and the plain old Ruby object way.
      def generic_send_email(method, mailer)
        config = sorcery_config
        mail = config.send(mailer).send(config.send(method),self)
        if defined?(ActionMailer) and config.send(mailer).superclass == ActionMailer::Base
          mail.deliver
        end
      end
      
      # Random code, used for salt and temporary tokens.
      def generate_random_token
        Digest::SHA1.hexdigest( Time.now.to_s.split(//).sort_by {rand}.join )
      end
    end

    # Each class which calls 'activate_sorcery!' receives an instance of this class.
    # Every submodule which gets loaded may add accessors to this class so that all 
    # options will be configured from a single place.
    class Config

      attr_accessor :username_attribute_name,           # change default username attribute, for example, to use :email
                                                        # as the login.
                                                        
                    :password_attribute_name,           # change *virtual* password attribute, the one which is used
                                                        # until an encrypted one is generated.
                                                        
                    :email_attribute_name,              # change default email attribute.
                    :crypted_password_attribute_name,   # change default crypted_password attribute.
                    :salt_join_token,                   # what pattern to use to join the password with the salt
                    :salt_attribute_name,               # change default salt attribute.
                    :stretches,                         # how many times to apply encryption to the password.
                    :encryption_key,                    # encryption key used to encrypt reversible encryptions such as
                                                        # AES256.
                                                        
                    :subclasses_inherit_config,         # make this configuration inheritable for subclasses. Useful for
                                                        # ActiveRecord's STI.
                    
                    :submodules,                        # configured in config/application.rb
                    :before_authenticate,               # an array of method names to call before authentication
                                                        # completes. used internally.
                                                        
                    :after_config                       # an array of method names to call after configuration by user.
                                                        # used internally.
                    
      attr_reader   :encryption_provider,               # change default encryption_provider.
                    :custom_encryption_provider,        # use an external encryption class.
                    :encryption_algorithm               # encryption algorithm name. See 'encryption_algorithm=' below
                                                        # for available options.

      def initialize
        @defaults = {
          :@submodules                           => [],
          :@username_attribute_name              => :username,
          :@password_attribute_name              => :password,
          :@email_attribute_name                 => :email,
          :@crypted_password_attribute_name      => :crypted_password,
          :@encryption_algorithm                 => :bcrypt,
          :@encryption_provider                  => CryptoProviders::BCrypt,
          :@custom_encryption_provider           => nil,
          :@encryption_key                       => nil,
          :@salt_join_token                      => "",
          :@salt_attribute_name                  => :salt,
          :@stretches                            => nil,
          :@subclasses_inherit_config            => false,
          :@before_authenticate                  => [],
          :@after_config                         => []
        }
        reset!
      end     
           
      # Resets all configuration options to their default values.
      def reset!
        @defaults.each do |k,v|
          instance_variable_set(k,v)
        end       
      end
      
      def custom_encryption_provider=(provider)
        @custom_encryption_provider = @encryption_provider = provider
      end
      
      def encryption_algorithm=(algo)
        @encryption_algorithm = algo
        @encryption_provider = case @encryption_algorithm
        when :none   then nil
        when :md5    then CryptoProviders::MD5
        when :sha1   then CryptoProviders::SHA1
        when :sha256 then CryptoProviders::SHA256
        when :sha512 then CryptoProviders::SHA512
        when :aes256 then CryptoProviders::AES256
        when :bcrypt then CryptoProviders::BCrypt
        when :custom then @custom_encryption_provider
        end
      end
      
    end
    
  end
end