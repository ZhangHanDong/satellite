# This is the main Satellite app. All business logic is contained here.
# - configuration is in config.rb
# - controller and view framework aka PicoFramework is in pico_framework.rb
# - "database" (Git interface) aka GitDB is in git_db.rb

%w{ configuration pico_framework git_db rubygems metaid redcloth open-uri erubis coderay }.each {|l| require l }

module Satellite
  # model definitions go here
  module Models
    PAGE_DIR = 'pages'
    UPLOAD_DIR = 'uploads'

    # "Hunk" is a model representing a file stored in the backend.
    # Hunks are saved locally in the filesystem, changes are committed to a
    # local Git repository which is mirrored to a master repository.
    # "Pages" and "Uploads" are types of Hunks.
    class Hunk
      VALID_FILENAME_CHARS = '\w \!\@\#\$\%\^\&\(\)\-\_\+\=\[\]\{\}\,\.'

      include Comparable

      # -----------------------------------------------------------------------
      # class methods
      # -----------------------------------------------------------------------

      class << self

        def valid_name?(name)
          name =~ /^[#{VALID_FILENAME_CHARS}]*$/
        end

        def exists?(name)
          File.exists?(filepath(name))
        end

        def list
          Dir[filepath('*')].collect {|s| self.new(parse_name(s)) }.sort
        end

        def load(name)
          if exists?(name)
            self.new(name)
          else
            raise GitDb::FileNotFound.new("#{self} #{name} does not exist")
          end
        end

        def rename(old_name, new_name)
          hunk = load(old_name)
          hunk.rename(new_name) if hunk && new_name != old_name
          hunk
        end

        # "foo.ext" (just the name by default)
        def filename(name); name; end

        # "pages/foo.ext"
        def local_filepath(name); File.join(content_dir, filename(name)); end

        # "path/to/pages/foo.ext"
        def filepath(name); File.join(CONF.data_dir, content_dir, filename(name)); end

        # try to extract the page name from the path
        def parse_name(path)
          if path =~ /^(.*\/)?([#{Hunk::VALID_FILENAME_CHARS}]+)$/
            $2
          else
            path
          end
        end
      end

      # -----------------------------------------------------------------------
      # instance methods
      # -----------------------------------------------------------------------

      def klass
        self.class
      end

      def name
        @name
      end

      # name= method is private (see below)

      def save(input)
        begin
          raise ArgumentError.new("Saved name can't be blank") unless name.any?
          save_file(input, filepath)
          GitDb.save(local_filepath, "Satellite: saving #{name}")
        rescue GitDb::ContentNotModified
          log :debug, "Hunk.save(): #{name} wasn't modified since last save"
        end
      end

      def rename(new_name)
        old_name = name
        self.name = new_name
        raise ArgumentError.new("New name can't be blank") unless name.any?
        GitDb.mv(klass.local_filepath(old_name), local_filepath, "Satellite: renaming #{old_name} to #{name}")
      end

      def delete!
        GitDb.rm(local_filepath, "Satellite: deleting #{name}")
      end

      def filename; klass.filename(name); end
      def local_filepath; klass.local_filepath(name); end
      def filepath; klass.filepath(name); end

      # sort home above other pages, otherwise alphabetical order
      def <=>(other)
        name <=> other.name
      end

    private

      def name=(name)
        name.strip!
        raise ArgumentError.new("Name is invalid: #{name}") unless klass.valid_name?(name)
        @name = name
      end

    end

    # "Page" is a Hunk representing a wiki page
    class Page < Hunk

      # -----------------------------------------------------------------------
      # class methods
      # -----------------------------------------------------------------------

      class << self
        def content_dir; PAGE_DIR; end

        def search(query)
          out = {}
          GitDb.search(query).each do |file,matches|
            page = Page.new(parse_name(file))
            out[page] = matches.collect do |line,text|
              text = WikiMarkup.process(text)
              text.gsub!(/<\/?[^>]*>/, '')
              [line, text]
            end
          end
          out
        end

        def conflicts
          GitDb.conflicts.collect {|c| Page.new(parse_name(c)) }.sort
        end

        def load(name)
          if exists?(name)
            Page.new(name, open(filepath(name)).read)
          else
            raise GitDb::FileNotFound.new("Page #{name} does not exist")
          end
        end

        # "foo.textile"
        def filename(name); "#{name}.textile"; end

        # try to extract the page name from the path
        def parse_name(path)
          if path =~ /^(.*\/)?([#{Hunk::VALID_FILENAME_CHARS}]+)\.textile$/
            $2
          else
            path
          end
        end
      end

      # -----------------------------------------------------------------------
      # instance methods
      # -----------------------------------------------------------------------

      def initialize(name='', body='')
        self.name = name
        self.body = body
      end

      def body(format=nil)
        case format
        when :html
          to_html
        else
          @body
        end
      end

      def body=(str='')
        if str.any?
          # fix line endings coming from browser
          str.gsub!(/\r\n/, "\n")

          # end page with newline if it doesn't have one
          str += "\n" unless str[-1..-1] == "\n"
        end
        @body = str
      end

      alias :original_save :save
      def save
        original_save(@body)
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
        WikiMarkup.process(@body)
      end
    end

    # "Upload" is a Hunk representing an uploaded file
    class Upload < Hunk

      # -----------------------------------------------------------------------
      # class methods
      # -----------------------------------------------------------------------

      class << self
        def content_dir; UPLOAD_DIR; end
      end

      # -----------------------------------------------------------------------
      # instance methods
      # -----------------------------------------------------------------------

      def initialize(name='')
        self.name = name
      end
    end

    # all the wiki markup stuff should go in here
    class WikiMarkup
      WIKI_LINK_FMT = /\{\{([#{Hunk::VALID_FILENAME_CHARS}]+)\}\}/
      UPLOAD_LINK_FMT = /\{\{upload:([#{Hunk::VALID_FILENAME_CHARS}]+)\}\}/

      AUTO_LINK_RE = %r{
                      (                          # leading text
                        <\w+.*?>|                # leading HTML tag, or
                        [^=!:\'\"/]|             # leading punctuation, or
                        ^                        # beginning of line
                      )
                      (
                        (?:https?://)|           # protocol spec, or
                        (?:www\.)                # www.*
                      )
                      (
                        [-\w]+                   # subdomain or domain
                        (?:\.[-\w]+)*            # remaining subdomains or domain
                        (?::\d+)?                # port
                        (?:/(?:(?:[~\w\+@%=-]|(?:[,.;:][^\s$]))+)?)* # path
                        (?:\?[\w\+@%&=.;-]+)?    # query string
                        (?:\#[\w\-]*)?           # trailing anchor
                      )
                      ([[:punct:]]|\s|<|$)       # trailing text
                     }x

      class << self
        def process(str)
          str = process_code_blocks(str)
          str = process_wiki_links(str)
          str = textile_to_html(str)
          str = autolink(str)
          str
        end

      private

        # code blocks are like so (where lang is ruby/html/java/c/etc):
        # {{{(lang)
        # @foo = 'bar'
        # }}}
        def process_code_blocks(str)
          str.gsub(/\{\{\{([\S\s]+?)\}\}\}/) do |s|
            code = $1
            if code =~ /^\((\w+)\)([\S\s]+)$/
              lang, code = $1.to_sym, $2.strip
            else
              lang = :plaintext
            end
            code = CodeRay.scan(code, lang).html.div
            # add surrounding newlines to avoid garbling during textile parsing
            "\n\n<notextile>#{code}</notextile>\n\n"
          end
        end

        # wiki links are like so: {{Another Page}}
        # uploads are like: {{upload:foo.ext}}
        def process_wiki_links(str)
          str.gsub(UPLOAD_LINK_FMT) do |s|
            name, uri = $1, PicoFramework::Controller::Uri.upload($1)
            notextile do
              if Upload.exists?(name)
                "<a href=\"#{uri}\">#{name}</a>"
              else
                "<span class=\"nonexistant\">#{name}</span>"
              end
            end
          end.gsub(WIKI_LINK_FMT) do |s|
            name, uri = $1, PicoFramework::Controller::Uri.page($1)
            notextile do
              if Page.exists?(name)
                "<a href=\"#{uri}\">#{name}</a>"
              else
                "<span class=\"nonexistant\">#{name}<a href=\"#{uri}\">?</a></span>"
              end
            end
          end
        end

        # helper to wrap wrap block in notextile tags (block should return html string)
        def notextile
          str = yield
          "<notextile>#{str.to_s}</notextile>" if str && str.any?
        end

        # textile -> html filtering
        def textile_to_html(str)
          RedCloth.new(str).to_html
        end

        # auto-link web addresses in plain text
        def autolink(str)
          str.gsub(AUTO_LINK_RE) do
            all, a, b, c, d = $&, $1, $2, $3, $4
            if a =~ /<a\s/i # don't replace URL's that are already linked
              all
            else
              "#{a}<a href=\"#{ b == 'www.' ? 'http://www.' : b }#{c}\">#{b + c}</a>#{d}"
            end
          end
        end
      end
    end
  end

  # controllers definitions go here
  module Controllers
    VALID_URI_CHARS = '\w \+\%\-\.'
    NAME = "([#{VALID_URI_CHARS}]+)"

    VALID_SEARCH_STRING_CHARS = '0-9a-zA-Z\+\%\`\~\!\^\*\(\)\_\-\[\]\{\}\\\|\'\"\.\<\>'
    SEARCH_STRING = "([#{VALID_SEARCH_STRING_CHARS}]+)"

    # reopen framework controller class to provide some app-specific logic
    class PicoFramework::Controller
      # pass title and uri mappings into templates too
      alias :original_render :render
      def render(template, title, params={})
        common_params = { :title => title, :uri => Uri, :conf => CONF,
          :pages => Models::Page.list, :conflicts => Models::Page.conflicts,
          :referrer => @referrer }
        original_render(template, params.merge!(common_params))
      end

      # for controllers that can share some page/upload logic
      # in general, pages should redirect back to the page itself,
      # and uploads should redirect back to the list page
      def page_or_upload(type, name)
        case type
        when 'page'
          @klass = Models::Page
          @cancel_uri = @referrer || Uri.page(name)
        when 'upload'
          @klass = Models::Upload
          @cancel_uri = @referrer || Uri.list
        end
      end
      
      # process a file upload
      def process_upload
        log :debug, "Uploaded: #{@input}"
        filename = @input['Filedata'][:filename].strip

        # save upload
        upload = Models::Upload.new(filename)
        upload.save(@input['Filedata'][:tempfile])
        
        # allow extra post-save logic
        yield upload if block_given?

        # respond with plain text (since it's a flash plugin)
        respond "Thanks!"
      end

      # uri mappings
      # TODO somehow generate these from routing table?
      class Uri
        class << self
          def page(name) "/page/#{escape(name)}" end
          def edit_page(name) "/page/#{escape(name)}/edit" end
          def rename(hunk)
            case hunk
            when Models::Page
              "/page/#{escape(hunk.name)}/rename"
            when Models::Upload
              "/upload/#{escape(hunk.name)}/rename"
            else
              log :error, "#{hunk} is neither a Page nor an Upload"
              ""
            end
          end
          def delete(hunk)
            case hunk
            when Models::Page
              "/page/#{escape(hunk.name)}/delete"
            when Models::Upload
              "/upload/#{escape(hunk.name)}/delete"
            else
              log :error, "#{hunk} is neither a Page nor an Upload"
              ""
            end
          end
          def resolve_conflict(name) "/page/#{escape(name)}/resolve" end
          def new_page() '/new' end
          def list() '/list' end
          def home() '/page/Home' end
          def search() '/search' end
          def upload(name) "/uploads/#{escape(name)}" end
          def upload_file(page_name=nil)
            if page_name
              "/page/#{escape(page_name)}/upload"
            else
              "/upload"
            end
          end
          def rename_upload(name) "/upload/#{escape(name)}/rename" end
          def delete_upload(name) "/upload/#{escape(name)}/delete" end
          def help() '/help' end
          def static(file)
            lastmod = File.ctime(File.join(CONF.static_dir, file)).strftime('%Y%m%d%H%M')
            "/static/#{file}?#{lastmod}"
          end
        end
      end
    end

    class IndexController < controller '/'
      def get; redirect Uri.home; end
      def post; redirect Uri.home; end
    end

    class PageController < controller "/page/#{NAME}", "/page/#{NAME}/(edit|resolve)"
      def get(name, action='view')
        # load page
        begin
          page = Models::Page.load(name)
        rescue GitDb::FileNotFound
          page = nil
        end

        # do stuff
        case action
        when 'view'
          if page
            render 'show_page', page.name, :page => page
          else
            redirect Uri.edit_page(name)
          end
        when 'edit'
          page ||= Models::Page.new(name)
          render 'edit_page', "Editing #{page.name}", :page => page
        when 'resolve'
          if page
            render 'resolve_conflict_page', "Resolving #{page.name}", :page => page
          else
            redirect Uri.edit_page(name)
          end
        else
          raise RuntimeError.new("PageController does not support the '#{action}' action.")
        end
      end

      def post(name, action=nil)
        page = Models::Page.new(name, @input['content'])
        page.save
        redirect Uri.page(page.name)
      end
    end

    class NewPageController < controller '/new'
      def get
        render 'new_page', 'Add page', :page => Models::Page.new
      end

      def post
        page = Models::Page.new(@input['name'].strip, @input['content'])
        unless Models::Page.exists?(page.name)
          page.save
          redirect Uri.page(page.name)
        else
          render 'new_page', 'Add page', :page => page, :error => "A page named #{page.name} already exists"
        end
      end
    end

    class RenameController < controller "/(page|upload)/#{NAME}/rename"
      def get(type, name)
        page_or_upload(type, name)
        hunk = @klass.load(name)
        render 'rename', "Renaming #{hunk.name}", :hunk => hunk, :cancel_uri => @cancel_uri
      end

      def post(type, name)
        page_or_upload(type, name)
        hunk = @klass.rename(name, @input['new_name'].strip)

        # figure out where to redirect to
        return_to = @input['return_to'].strip
        if return_to.any? && return_to != Uri.send(type, name)
          redirect return_to
        elsif @klass == Models::Page
          redirect Uri.page(hunk.name)
        elsif @klass == Models::Upload
          redirect Uri.list
        end
      end
    end

    class DeleteController < controller "/(page|upload)/#{NAME}/delete"
      def get(type, name)
        page_or_upload(type, name)
        hunk = @klass.load(name)
        render 'delete', "Deleting #{hunk.name}", :hunk => hunk, :cancel_uri => @cancel_uri
      end

      def post(type, name)
        page_or_upload(type, name)
        hunk = @klass.load(name)
        hunk.delete!
        redirect Uri.list
      end
    end

    class ListController < controller '/list'
      def get
        # @pages is populated for all pages, since it is used in goto jump box
        render 'list', 'All pages and uploads', :uploads => Models::Upload.list
      end
    end

    class SearchController < controller '/search', "/search\\?query=#{SEARCH_STRING}"
      def get(query=nil)
        if query
          log :debug, "searched for: #{query}"
          results = Models::Page.search(query)
          render 'search', "Searched for: #{query}", :query => query, :results => results
        else
          render 'search', 'Search'
        end
      end
    end

    class PageUploadController < controller "/page/#{NAME}/upload"
      def post(name)
        process_upload do |upload|
          # add upload to current page
          page = Models::Page.load(name)
          page.body += "\n\n* {{upload:#{upload.name}}}"
          page.save
        end
      end
    end

    class UploadController < controller '/upload', "/upload/#{NAME}"
      def get(name='')
        # files are served up directly by Mongrel (at URI "/uploads")
        redirect Uri.upload(name)
      end
      
      def post
        process_upload
      end
    end
    
    class HelpController < controller '/help'
      def get
        render 'help', 'Help'
      end
    end
  end

  class << self
    def sync
      log :debug, "Synchronizing with master repository."
      begin
        GitDb.sync
      rescue GitDb::MergeConflict => e
        # TODO surface on front-end? already happens on page-load, though...
        log :warn, "Encountered conflicts during sync. The following files must be merged manually:" +
          GitDb.conflicts.collect {|c| "  * #{c}" }.join("\n")
      rescue GitDb::ConnectionFailed
        log :warn, "Failed to connect to master repository during sync operation."
      end
      log :debug, "Sync complete."
    end

    def server
      PicoFramework::Server.new(CONF.server_ip, CONF.server_port, Controllers, { '/uploads' => File.join(CONF.data_dir, Models::UPLOAD_DIR) })
    end
    
    def start
      # kill the whole server if an unexpected exception is encounted in the sync
      Thread.abort_on_exception = true

      # perform initial sync (not in thread, so that server waits to start up)
      sync

      # spawn thread to sync with master repository
      Thread.new do
        while true
          # sleep until next sync
          sleep CONF.sync_frequency
          sync
        end
      end

      # start server
      server.start
    end
  end
end
