#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

module Instructure #:nodoc:
  module SanitizeField #:nodoc:

    def self.included(klass)
      klass.extend(ClassMethods)
    end

    # modified from sanitize.rb to support mid-value matching
    REGEX_STYLE_PROTOCOL = /([A-Za-z0-9\+\-\.\&\;\#\s]*?)(?:\:|&#0*58|&#x0*3a)\/\//i
    REGEX_STYLE_METHOD = /([A-Za-z0-9\+\-\.\&\;\#\s]*?)(?:\(|&#0*40|&#x0*28)/i

    # used as a sanitize.rb transformer, below
    def self.sanitize_style(env)
      node = env[:node]
      styles = []
      style = node['style'] || ""
      # taken from https://github.com/flavorjones/loofah/blob/master/lib/loofah/html5/scrub.rb
      # the gauntlet
      #style = '' unless style =~ /\A([:,\;#%.\(\)\/\sa-zA-Z0-9!]|\w-\w|\'[\s\w]+\'|\"[\s\w]+\"|\([\d,\s]+\))*\z/
      style = '' unless style =~ /\A([:,\;#%.\(\)\/\sa-zA-Z0-9!?=&_\-]|\w-\w|\'[\s\w]+\'|\"[\s\w]+\"|\([\d,\s]+\))*\z/ || style =~ /url\s*\(['"]\s*(https|http|[.\/\\])/i
      style = '' unless style =~ /\A\s*([-\w]+\s*:[^\;]*(\;\s*|$))*\z/
      
      config = env[:config]

      style.scan(/([-\w]+)\s*:\s*([^;]*)/) do |property, value|
        property = property.downcase
        valid = (config[:style_properties] || []).include?(property)
        valid ||= (config[:style_expressions] || []).any?{|e| property.match(e) }
        if valid
          styles << [property, clean_style_value(config, value)]
        end
      end
      node['style'] = styles.select { |k,v| v }.map{|k,v| "#{k}: #{v}"}.join('; ') + ";"
    end

    def self.clean_style_value(config, value)
      # checks for any colons anywhere in the string
      # to make sure they're preceded by a valid protocol
      protocols = config[:protocols]['style']['any']

      # no idea what these are called in css, but it's
      # a name followed by open-paren 
      # (i.e. url(...) or expression(...))
      methods = config[:style_methods]

      if methods
        value.to_s.downcase.scan(REGEX_STYLE_METHOD) do |match|
          return nil if !methods.include?(match[0].strip.downcase)
        end
      end
      if protocols
        value.to_s.downcase.scan(REGEX_STYLE_PROTOCOL) do |match|
          return nil if !protocols.include?(match[0].strip.downcase)
        end
      end
      value
    end

    SANITIZE = {
      :elements => [
        'a', 'b', 'blockquote', 'br', 'caption', 'cite', 'code', 'col',
        'hr', 'h2', 'h3', 'h4', 'h5', 'h6', 'h7', 'h8',
        'del', 'ins', 'iframe',
        'colgroup', 'dd', 'div', 'dl', 'dt', 'em', 'figure', 'figcaption', 'i', 'img', 'li', 'ol', 'p', 'pre',
        'q', 'small', 'span', 'strike', 'strong', 'sub', 'sup', 'table', 'tbody', 'td',
        'tfoot', 'th', 'thead', 'tr', 'u', 'ul', 'object', 'embed', 'param'],

      :attributes => {
        :all        => ['style', 'class', 'id'],
        'a'          => ['href', 'title', 'target', 'name'],
        'blockquote' => ['cite'],
        'col'        => ['span', 'width'],
        'colgroup'   => ['span', 'width'],
        'img'        => ['align', 'alt', 'height', 'src', 'title', 'width'],
        'iframe'     => ['src', 'width', 'height', 'name', 'align', 'frameborder', 'scrolling', 'sandbox'],
        'ol'         => ['start', 'type'],
        'q'          => ['cite'],
        'table'      => ['summary', 'width', 'border', 'cellpadding', 'cellspacing', 'center', 'frame', 'rules', 'dir', 'lang'],
        'tr'         => ['align', 'valign', 'dir'],
        'td'         => ['abbr', 'axis', 'colspan', 'rowspan', 'width', 'align', 'valign', 'dir'],
        'th'         => ['abbr', 'axis', 'colspan', 'rowspan', 'width', 'align', 'valign', 'dir', 'scope'],
        'ul'         => ['type'],
        'param'      => ['name', 'value'],
        'object'     => ['width', 'height', 'style', 'data', 'type', 'classid', 'codebase'],
        'embed'      => ['name', 'src', 'type', 'allowfullscreen', 'pluginspage', 'wmode', 'allowscriptaccess', 'width', 'height']
      },

      :protocols => {
        'a'          => {'href' => ['ftp', 'http', 'https', 'mailto',
                                    :relative]},
        'blockquote' => {'cite' => ['http', 'https', :relative]},
        'img'        => {'src'  => ['http', 'https', 'data', :relative]},
        'q'          => {'cite' => ['http', 'https', :relative]},
        'object'     => {'data' => ['http', 'https', :relative]},
        'embed'      => {'src'  => ['http', 'https', :relative]},
        'iframe'     => {'src'  => ['http', 'https', :relative]},
        'style'      => {'any'  => ['http', 'https', :relative]}
      },
      :style_methods => ['url'],
      :style_properties => [
        'background', 'border', 'clear', 'color',
        'cursor', 'direction', 'display', 'float',
        'font', 'height', 'left', 'line-height',
        'list-style', 'margin', 'max-height',
        'max-width', 'min-height', 'min-width',
        'overflow', 'overflow-x', 'overflow-y',
        'padding', 'position', 'right',
        'text-align', 'table-layout',
        'text-decoration', 'text-indent',
        'top', 'vertical-align',
        'visibility', 'white-space', 'width',
        'z-index', 'zoom'
      ],
      :style_expressions => [
        /\Abackground-(?:attachment|color|image|position|repeat|size)\z/,
        /\Abackground-position-(?:x|y)\z/,
        /\Aborder-(?:bottom|collapse|color|left|right|spacing|style|top|width)\z/,
        /\Aborder-(?:bottom|left|right|top)-(?:color|style|width)\z/,
        /\Afont-(?:family|size|stretch|style|variant|weight)\z/,
        /\Alist-style-(?:image|position|type)\z/,
        /\Amargin-(?:bottom|left|right|top|offset)\z/,
        /\Apadding-(?:bottom|left|right|top)\z/
      ],
      :transformers => lambda { |env| Instructure::SanitizeField.sanitize_style(env) if env[:node]['style'] }
    }

    module ClassMethods
      
      def sanitize_field(*args)
        # Calls this as many times as a field is configured.  Will this play
        # nicely? 
        include Instructure::SanitizeField::InstanceMethods
        extend Instructure::SanitizeField::SingletonMethods

        @config = OpenStruct.new
        @config.sanitizer = []
        @config.fields = []
        @config.allow_comments = true
        args.each { |arg| infer_sanitize_arg(arg) }
        @config.fields.each { |field| write_inheritable_hash(:fully_sanitize_fields, {field => @config.sanitizer.first} ) }

        before_save :fully_sanitize_fields
      end
      
      protected
      
        def infer_sanitize_arg(arg)
          case arg
          when Symbol
            @config.fields << arg
          when Hash
            @config.sanitizer << arg
          when Sanitize::Config::RELAXED
            @config.sanitizer << arg
          when Sanitize::Config::BASIC
            @config.sanitizer << arg
          when Sanitize::Config::RESTRICTED
            @config.sanitizer << arg
          end
        end
        
    end # ClassMethods
      
    module SingletonMethods
      # None right now
    end # SingletonMethods
    
    module InstanceMethods
      protected

        # This should be a protected method on the class.  It should run a
        # different sanitizer on every field being sanitized, using any
        # configuration set for that specific field or 
        # Sanitize::Config::RESTRICTED as the default. 
        def fully_sanitize_fields
          fields_hash = self.class.read_inheritable_attribute(:fully_sanitize_fields) || {}
          fields_hash.each do |field, config|
            config ||= Sanitize::Config::RESTRICTED
            config = Sanitize::Config::RESTRICTED if config.empty?
            # Doesn't try to sanitize nil
            f = self.send(field)
            next unless f
            next unless f.is_a?(String) or f.is_a?(IO)
            val = Sanitize.clean(f, config) 
            self.send((field.to_s + "="), val)
          end
        end

    end # InstanceMethods
  end # SanitizeField
end # Instructure
