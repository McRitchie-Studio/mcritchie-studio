# frozen_string_literal: true

module ClientApps
  module StudioKit
    # Places the shell into one served HTML page. It never re-serialises the
    # bundle's HTML (that would rewrite model-written markup); it inserts at
    # three tag boundaries and leaves every other byte as written:
    #
    #   <head ...>     the kit's <link>, the theme, the kit's <script>, first,
    #                  so the bundle's own CSS still has the last word
    #   <body ...>     gains data-studio-kit, and the navbar right after it
    #   </body>        the footer right before the LAST one
    #
    # The tags are found by ClientAppMarkup, the same scanner the publish check
    # reads a page with, so a `<body>` inside a comment, a quoted attribute, or a
    # title, script, style or textarea is text, never the place the navbar goes.
    #
    # A page missing a tag still gets the whole shell: no <head>, the head goes
    # after <html ...> or the doctype (or first); no <body> tag, the host opens
    # one after </head> (or after the head it added); no </body>, the footer
    # goes before </html> (or last). Browsers build the same document from
    # either placement.
    module Wrap
      # Where each piece goes, per page: found once per page's bytes (the
      # manifest's sha256 names them, and a version's bytes never change), so a
      # page view scans nothing.
      Points = Struct.new(:head, :head_wrap, :body_open, :body_tag, :footer, keyword_init: true)

      POINTS_LIMIT = 512
      @points = {}
      @points_mutex = Mutex.new

      class << self
        def call(html, shell, key: nil)
          page = html.to_s.dup.force_encoding(Encoding::UTF_8)
          page = page.scrub unless page.valid_encoding?
          at = key ? cached_points(key) { points(page) } : points(page)
          assemble(page, shell, at)
        end

        # The insertion points in PAGE (String indices).
        #   head       where the head pieces go
        #   head_wrap  true when the page has no <head> tag (they get one)
        #   body_open  where the navbar goes; body_tag is the page's own <body>
        #              tag to rewrite with data-studio-kit, or nil (one is opened)
        #   footer     where the footer goes
        def points(page)
          markup = ClientAppMarkup.new(page)
          body = markup.first_start("body")
          head = markup.first_start("head")
          head = nil if head && body && head.from > body.from
          head_close = markup.first_end("head")
          head_close = nil if head_close && body && head_close.from > body.from
          html_open = markup.first_start("html")
          doctype_end = page.match(/\A\s*<!doctype[^>]*>/i)&.end(0)
          close = markup.last_end("body") || markup.last_end("html")

          head_at = head&.to || html_open&.to || doctype_end || 0
          body_at = if body then body.from
                    elsif head_close then head_close.to
                    end
          Points.new(head: head_at, head_wrap: head.nil?, body_open: body_at, body_tag: body,
                     footer: close ? close.from : page.length)
        end

        private

        def assemble(page, shell, at)
          head = at.head_wrap ? "\n<head>\n#{shell.head}\n</head>\n" : "\n#{shell.head}\n"
          inserts = [ [ at.head, head, 0, 0 ] ]
          if at.body_tag
            tag = page[at.body_tag.from...at.body_tag.to]
            opened = tag.sub(/\A<body/i, "<body data-studio-kit")
            inserts << [ at.body_tag.from, "#{opened}\n#{shell.navbar}\n", at.body_tag.to - at.body_tag.from, 1 ]
          else
            # No <body> tag: open one right after the head (after the head the
            # kit added, when the page had none), so the hook and the navbar
            # lead the body.
            where = at.body_open || at.head
            inserts << [ where, "\n<body data-studio-kit>\n#{shell.navbar}\n", 0, 1 ]
          end
          inserts << [ at.footer, "#{shell.footer}\n", 0, 2 ]
          splice(page, inserts)
        end

        # Applies [index, text, replaced length, rank] edits from the back, so
        # each index still names the original page. Edits at one index land in
        # rank order (head, then body, then footer).
        def splice(page, inserts)
          out = page.dup
          inserts.sort_by { |index, _, _, rank| [ -index, -rank ] }.each { |index, text, replaced, _| out[index, replaced] = text }
          out
        end

        def cached_points(key)
          hit = @points_mutex.synchronize { @points[key] }
          return hit if hit

          found = yield
          @points_mutex.synchronize do
            @points.shift while @points.size >= POINTS_LIMIT
            @points[key] = found
          end
        end
      end
    end
  end
end
