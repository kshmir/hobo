  module Dryml

    # Raised when the part context fails its integrity check.
    class PartContext

      class TamperedWithPartContext < StandardError; end

      class TypedId < String; end

      class << self
        attr_accessor :secret, :digest
      end
      self.digest = 'SHA1'


      def self.client_side_storage_uncoded(contexts, session)
        contexts.inject({}) do |h, (dom_id, context)|
          h[dom_id] = context.marshal(session)
          h
        end
      end

      def self.pre_marshal(x)
        if x.is_a?(ActiveRecord::Base) && x.respond_to?(:typed_id)
          TypedId.new(x.typed_id)
        else
          x
        end
      end


      def self.for_call(part_name, environment, locals)
        new do |c|
          c.part_name       = part_name
          c.locals          = locals.map { |l| pre_marshal(l) }
          c.this_id         = environment.typed_id
          c.form_field_path = environment.form_field_path
        end
      end


      def self.for_refresh(encoded_context, page_this, session)
        new do |c|
          c.unmarshal(encoded_context, page_this, session)
        end
      end


      def initialize
        yield self
      end

      attr_accessor :part_name, :locals, :this, :this_field, :this_id, :form_field_path


      def marshal(session)
        context = [@part_name, @this_id, @locals]
        context << form_field_path if form_field_path
        # http://stackoverflow.com/questions/2620975/strange-n-in-base64-encoded-string-in-ruby
        # data = Base64.encode64(Marshal.dump(context)).strip
        data = Base64.strict_encode64(Marshal.dump(context)).strip
        digest = generate_digest(data, session)
        "#{data}--#{digest}"
      end


      # Unmarshal part context to a hash and verify its integrity.
      def unmarshal(client_store, page_this, session)
        data, digest = CGI.unescape(client_store).strip.split('--')
        raise TamperedWithPartContext unless digest == generate_digest(data, session)

        context = Marshal.load(Base64.decode64(data))

        part_name, this_id, locals, form_field_path = context

        if Rails
          Rails.logger.info "Call part: #{part_name}. this-id = #{this_id}, locals = #{locals.inspect}"
          Rails.logger.info "         : form_field_path = #{form_field_path.inspect}" if form_field_path
        end

        self.part_name             = part_name
        self.this_id               = this_id
        self.locals                = restore_locals(locals)
        self.form_field_path       = form_field_path

        parse_this_id(page_this)
      end


      # Generate the HMAC keyed message digest. Uses SHA1 by default.
      def generate_digest(data, session)
        secret = self.class.secret || Rails.application.config.secret_key_base || Rails.application.config.secret_token
        key = secret.respond_to?(:call) ? secret.call(session) : secret
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new(self.class.digest), key, data)
      end



      def parse_this_id(page_this)
        if this_id.nil? || this_id =="nil"
          nil
        elsif this_id == "this" || this_id == page_this._?.typed_id
          self.this = page_this
        elsif this_id =~ /^this:(.*)/ || (page_this._?.typed_id && this_id =~ /^#{page_this._?.typed_id}:(.*)/)
          self.this = page_this
          self.this_field = $1
        else
          parts = this_id.split(':')
          if parts.length == 3
            self.this       = Hobo::Model.find_by_typed_id("#{parts[0]}:#{parts[1]}")
            self.this_field = parts[2]
          else
            self.this = Hobo::Model.find_by_typed_id(this_id)
          end
        end
      end


      def restore_locals(locals)
        locals.map do |l|
          if l.is_a?(TypedId)
            Hobo::Model.find_by_typed_id(l)
          else
            l
          end
        end
      end

    end

  end
