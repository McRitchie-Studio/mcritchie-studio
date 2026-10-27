# frozen_string_literal: true

require "open3"

module MarketingKit
  # Prints an HTML page to PDF with headless Chrome: the only renderer on hand
  # that loads Google Fonts and honours break-after:page. File access is on so
  # the page's file:// images load.
  module ChromePdf
    CHROME = ENV.fetch("CHROME_BIN", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

    module_function

    def print(html_path, pdf_path)
      raise Error, "Chrome not found at #{CHROME} (set CHROME_BIN)" unless File.executable?(CHROME)

      out, status = Open3.capture2e(CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                                    "--allow-file-access-from-files", "--virtual-time-budget=15000",
                                    "--print-to-pdf=#{pdf_path}", "file://#{File.expand_path(html_path)}")
      raise Error, "Chrome could not print #{html_path}:\n#{out}" unless status.success? && File.size?(pdf_path)

      pdf_path
    end
  end
end
