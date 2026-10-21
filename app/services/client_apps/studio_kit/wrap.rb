# frozen_string_literal: true

module ClientApps
  module StudioKit
    # Places the shell into one served HTML page. It never parses and
    # re-serialises the bundle's HTML (that would rewrite model-written markup);
    # it inserts at three tag boundaries and leaves every other byte as written:
    #
    #   <head ...>     the kit's <link>, the theme, the kit's <script>, first,
    #                  so the bundle's own CSS still has the last word
    #   <body ...>     gains data-studio-kit, and the navbar right after it
    #   </body>        the footer right before the LAST one
    #
    # A page missing a tag still gets the whole shell: no <head>, the head goes
    # after <html ...> (or first); no <body>, the navbar goes after </head> (or
    # after the head part); no </body>, the footer goes before </html> (or last).
    # Browsers build the same document from either placement.
    module Wrap
      HEAD_OPEN = /<head(?:\s[^>]*)?>/i
      HTML_OPEN = /<html(?:\s[^>]*)?>/i
      HEAD_CLOSE = %r{</head\s*>}i
      BODY_OPEN = /<body(\s[^>]*)?>/i
      BODY_CLOSE = %r{</body\s*>}i
      HTML_CLOSE = %r{</html\s*>}i
      DOCTYPE = /\A\s*<!doctype[^>]*>/i

      module_function

      def call(html, shell)
        page = html.to_s.dup.force_encoding(Encoding::UTF_8)
        page = page.scrub unless page.valid_encoding?
        page = insert_head(page, shell.head)
        page = insert_navbar(page, shell.navbar)
        insert_footer(page, shell.footer)
      end

      def insert_head(page, head)
        return after(page, page.match(HEAD_OPEN), "\n#{head}\n") if page.match?(HEAD_OPEN)
        return after(page, page.match(HTML_OPEN), "\n<head>\n#{head}\n</head>\n") if page.match?(HTML_OPEN)
        return after(page, page.match(DOCTYPE), "\n<head>\n#{head}\n</head>\n") if page.match?(DOCTYPE)

        "<head>\n#{head}\n</head>\n#{page}"
      end

      def insert_navbar(page, navbar)
        if (match = page.match(BODY_OPEN))
          tag = "<body data-studio-kit#{match[1]}>"
          return "#{match.pre_match}#{tag}\n#{navbar}\n#{match.post_match}"
        end

        # No <body> tag: the parser opens the body at the first content, so the
        # navbar goes right after the head.
        close = page.match(HEAD_CLOSE)
        close ? after(page, close, "\n#{navbar}\n") : "#{page}\n#{navbar}"
      end

      def insert_footer(page, footer)
        index = last_index(page, BODY_CLOSE) || last_index(page, HTML_CLOSE)
        return "#{page}\n#{footer}\n" unless index

        "#{page[0...index]}#{footer}\n#{page[index..]}"
      end

      def after(page, match, text) = "#{match.pre_match}#{match[0]}#{text}#{match.post_match}"

      def last_index(page, pattern)
        index = nil
        page.scan(pattern) { index = Regexp.last_match.begin(0) }
        index
      end
    end
  end
end
