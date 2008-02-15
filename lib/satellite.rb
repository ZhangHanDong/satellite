#!/bin/env ruby

# This is the main Satellite app. All business logic is contained here. 
# - configuration is in config.rb
# - controller and view framework is in framework.rb
# - "database" aka Git interface is in db.rb

%w{ config framework db rubygems metaid redcloth open-uri erubis }.each {|l| require l }

module Satellite

  # "Page" is a model representing a wiki page
  # Pages are saved locally in the filesystem, changes are committed to a local
  # Git repository which is mirrored to a master repository
  class Page
    include Comparable
    
    VALID_NAME_CHARS = '\w \!\@\#\$\%\^\&\(\)\-\_\+\=\[\]\{\}\,\.'
    WIKI_LINK_FMT = /\{\{([#{VALID_NAME_CHARS}]+)\}\}/
  
    PAGE_DIR = 'pages'
    PAGE_PATH = File.join(Conf::DATA_DIR, PAGE_DIR)
    
    # static methods
    class << self
      def list
        Dir[filepath('*')].collect {|s| s.sub(/^#{PAGE_PATH}\/(.+)\.textile$/, '\1') }.collect {|s| Page.new(s) }.sort
      end

      def load(name)
        if exists?(name)
          Page.new(name, open(filepath(name)).read)
        else
          nil
        end
      end

      def exists?(name)
        File.exists?(filepath(name))
      end

      # "foo.textile"
      def filename(name); "#{name}.textile"; end

      # "path/to/foo.textile"
      def filepath(name); File.join(PAGE_PATH, filename(name)); end
    end
  
    # instance methods
    attr_reader :name
    attr_writer :body

    def initialize(name='', body='')
      @name = name
      @body = body
      raise ArgumentError.new("Name is invalid: #{name}") if name.any? && !valid_name?
    end

    def body(format=nil)
      case format
      when :html
        to_html
      else
        @body
      end
    end
  
    def save
      begin
        save_file(@body, filepath)
        relative_path = File.join(PAGE_DIR, filename)
        Db.save(relative_path, "Satellite: saving #{name}")
      rescue Db::ContentNotModified
        log "Didn't need to save #{name}"
      end
    end
  
    def valid_name?
      name =~ /^[#{VALID_NAME_CHARS}]+$/
    end
    
    # sort home above other pages, otherwise alphabetical order
    def <=>(other)
      if name == 'Home'
        -1
      elsif other.name == 'Home'
        1
      else
        name <=> other.name
      end
    end
    
    def to_html
      str = @body
      
      # wiki linking
      str = str.gsub(WIKI_LINK_FMT) do |s|
        name, uri = $1, WikiController::Uri.page($1)
        notextile do
          if Page.exists?(name)
            "<a href=\"#{uri}\">#{name}</a>"
          else
            "<span class=\"nonexistant\">#{name}<a href=\"#{uri}\">?</a></span>"
          end 
        end
      end
      
      # textile -> html filtering
      RedCloth.new(str).to_html
    end
  
    def filename; Page.filename(name); end
    def filepath; Page.filepath(name); end
    
    # helper to wrap wrap block in notextile tags (block should return html string)
    def notextile
      str = yield
      "<notextile>#{str.to_s}</notextile>" if str && str.any?
    end
  end

  # The wiki controller just wraps the base framework mongrel request handler
  # to provide some
  class WikiController < RequestHandler
    VALID_CHARS = '\w \+\%\-\.'
    NAME = "([#{VALID_CHARS}]+)"
  
    alias :original_render :render
    def render(template, title, params={})
      original_render(template, params.merge!({ :title => title, :uri => Uri }))
    end
  
    class Uri
      class << self
        def page(name) "/page/#{RequestHandler.escape(name)}" end
        def edit_page(name) "/page/#{RequestHandler.escape(name)}/edit" end
        def new_page() '/new' end
        def list() '/list' end
        def home() '/page/Home' end
      end
    end
  end

  # TODO it would be nice to have this be like camping, with something like < R "/page/(.+)"
  # instead of the inherit block. the necessary method might look like:
  #
  # see: http://whytheluckystiff.net/articles/seeingMetaclassesClearly.html
  # def R(uri_format)
  #   Class.new(RequestHandler) do
  #     meta_def(:uri_format) { uri_format }
  #   end
  # end
  #
  class PageController < WikiController
    def initialize
      super "/page/#{NAME}", "/page/#{NAME}/(edit)"
    end
  
    def get(name, action='view')
      page = Page.load(name)
      case action
      when 'view'
        if page
          render 'show_page', page.name, :page => page
        else
          redirect Uri.edit_page(name)
        end
      when 'edit'
        page ||= Page.new(name)
        render 'edit_page', "Editing #{page.name}", :page => page
      end
    end
  
    def post(name, action=nil)
      page = Page.new(name, @input['content'])
      page.save
      redirect Uri.page(page.name)
    end
  end

  class NewPageController < WikiController
    def initialize
      super '/new'
    end
  
    def get
      render 'new_page', 'Add page', :page => Page.new
    end
  
    def post
      page = Page.new(@input['name'].strip, @input['content'])
      unless Page.exists?(page.name)
        page.save
        redirect Uri.page(page.name)
      else
        render 'new_page', 'Add page', :page => page, :error => "A page named #{page.name} already exists"
      end
    end
  end

  class ListController < WikiController
    def initialize
      super '/list'
    end
  
    def get
      render 'list_pages', 'All pages', :pages => Page.list
    end
  end

  ROUTES = [ 
    [ '/', '/page/Home' ],
    [ '/page', PageController.new ],
    [ '/new', NewPageController.new ],
    [ '/list', ListController.new ]
  ]

  class << self
    def start
      Server.new(Conf::SERVER_IP, Conf::SERVER_PORT, ROUTES).start
    end
  end
end
