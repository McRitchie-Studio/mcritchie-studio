# frozen_string_literal: true

module DomainCutover
  # One DNS record, normalised so a DoH answer and a Cloudflare API row compare
  # equal when they mean the same thing: names lowercase without the trailing dot,
  # hostnames likewise, TXT unquoted with its 255-byte segments joined, MX split
  # into priority and host. `proxied` is Cloudflare's orange cloud; nil when the
  # record came from DNS, which cannot see it.
  Record = Struct.new(:name, :type, :content, :priority, :proxied, :id, keyword_init: true) do
    def key = [name, type, content, priority]
    def group = [name, type]

    def to_s
      pri = priority ? "#{priority} " : ""
      cloud = proxied.nil? ? "" : (proxied ? " (proxied)" : " (DNS only)")
      "#{name} #{type} #{pri}#{type == 'TXT' ? content.inspect : content}#{cloud}"
    end
  end

  module Records
    # The record types the move copies. SRV, NS below the apex and other rarities
    # are not read: DoH can only answer the names we ask about, and the plan lists
    # what it read so a missing one is visible (domain-dns § Cloudflare DNS).
    COPIED_TYPES = %w[A AAAA CNAME MX TXT CAA].freeze

    # The names every snapshot reads, relative to the domain ("" is the apex).
    # DoH cannot list a zone, so the snapshot is these, plus every --name the
    # operator adds, plus every name Cloudflare's own import found. The `in.` and
    # `send.` rows are here because a past move dropped an inbound MX under `in.`.
    DEFAULT_NAMES = ["", "www", "google._domainkey", "_dmarc", "resend._domainkey",
                     "send", "in", "send.in", "mail", "qa"].freeze

    module_function

    def name(text) = text.to_s.strip.downcase.delete_suffix(".")

    def host(text) = name(text)

    # "a" "b" -> ab; an unquoted value is kept as it is.
    def unquote_txt(text)
      text = text.to_s.strip
      return text unless text.start_with?('"')

      text.scan(/"((?:[^"\\]|\\.)*)"/).map { |(seg)| seg.gsub(/\\(.)/, '\1') }.join
    end

    def caa(text)
      flags, tag, value = text.to_s.strip.split(/\s+/, 3)
      %(#{flags.to_i} #{tag.to_s.downcase} "#{value.to_s.delete('"')}")
    end

    # Build a Record from a type and the presentation-format data DoH returns.
    def from_dns(owner, type, data)
      owner = name(owner)
      case type
      when "MX"
        pri, target = data.to_s.strip.split(/\s+/, 2)
        Record.new(name: owner, type: type, content: host(target), priority: pri.to_i)
      when "CNAME", "NS" then Record.new(name: owner, type: type, content: host(data))
      when "TXT" then Record.new(name: owner, type: type, content: unquote_txt(data))
      when "CAA" then Record.new(name: owner, type: type, content: caa(data))
      when "AAAA" then Record.new(name: owner, type: type, content: data.to_s.strip.downcase)
      else Record.new(name: owner, type: type, content: data.to_s.strip)
      end
    end

    # Build a Record from a Cloudflare dns_records row.
    def from_cloudflare(row)
      type = row["type"]
      content = case type
                when "MX", "CNAME", "NS" then host(row["content"])
                when "TXT" then unquote_txt(row["content"])
                when "CAA"
                  data = row["data"] || {}
                  data.empty? ? caa(row["content"]) : caa("#{data['flags']} #{data['tag']} #{data['value']}")
                when "AAAA" then row["content"].to_s.downcase
                else row["content"].to_s
                end
      Record.new(name: name(row["name"]), type: type, content: content,
                 priority: type == "MX" ? row["priority"].to_i : nil, proxied: row["proxied"], id: row["id"])
    end

    # The JSON body Cloudflare takes to create or update this record. TTL 1 is
    # Cloudflare's "auto": a TTL read over DoH is what is left in a cache, not what
    # the old zone set, so copying it would copy noise.
    def cloudflare_body(rec)
      body = { "type" => rec.type, "name" => rec.name, "ttl" => 1, "proxied" => rec.proxied ? true : false }
      case rec.type
      when "MX" then body.merge!("content" => rec.content, "priority" => rec.priority)
      when "CAA"
        flags, tag, value = rec.content.split(/\s+/, 3)
        body["data"] = { "flags" => flags.to_i, "tag" => tag, "value" => value.delete('"') }
      else body["content"] = rec.content
      end
      body
    end

    # Records Cloudflare cannot proxy (only A, AAAA and CNAME can be orange).
    def proxiable?(rec) = %w[A AAAA CNAME].include?(rec.type)

    # The zone the move must end with: every snapshot record copied exactly and DNS
    # only, except the two app records that replace whatever the old zone had at
    # the apex and at www (Squarespace's forwarding A records, a www CNAME):
    #   @   CNAME <heroku target>  DNS only (Cloudflare flattens a CNAME at the apex)
    #   www CNAME <domain>         proxied  (an edge redirect only runs on proxied traffic)
    def desired(domain, snapshot, heroku_target)
      domain = name(domain)
      www = "www.#{domain}"
      replaced = lambda do |rec|
        (rec.name == domain && %w[A AAAA CNAME].include?(rec.type)) || rec.name == www && rec.type != "TXT"
      end
      kept = snapshot.reject(&replaced).map { |r| r.dup.tap { |c| c.proxied = false; c.id = nil } }
      app = [
        Record.new(name: domain, type: "CNAME", content: host(heroku_target), proxied: false),
        Record.new(name: www, type: "CNAME", content: domain, proxied: true)
      ]
      (kept + app).uniq(&:key)
    end

    # What it takes to turn `current` (the zone, re-listed) into `desired`.
    #   create  desired records the zone lacks
    #   update  records present with the wrong proxy flag
    #   delete  zone records that CONFLICT with a desired one: same name and type
    #           where the type allows one answer (CNAME), or any A/AAAA/CNAME at a
    #           name where the desired record is a CNAME (a CNAME cannot share its
    #           name with them). Nothing else is deleted: a record Cloudflare's
    #           import found that the DoH snapshot did not is real data the
    #           snapshot could not see, so it is kept and reported.
    #   extra   those kept records
    def reconcile(desired, current)
      by_key = current.group_by(&:key)
      cname_names = desired.select { |r| r.type == "CNAME" }.map(&:name)
      delete = current.select do |r|
        next false if desired.any? { |d| d.key == r.key }

        cname_names.include?(r.name) && %w[A AAAA CNAME].include?(r.type)
      end
      create = desired.reject { |d| by_key.key?(d.key) }
      update = desired.filter_map do |d|
        row = by_key[d.key]&.first
        next unless row && proxiable?(d) && row.proxied != d.proxied

        row.dup.tap { |u| u.proxied = d.proxied }
      end
      extra = current.reject { |r| desired.any? { |d| d.key == r.key } || delete.include?(r) }
      { create: create, update: update, delete: delete, extra: extra }
    end

    # Desired records the zone does not hold exactly (by content and proxy flag).
    def missing(desired, current)
      desired.reject do |d|
        current.any? { |c| c.key == d.key && (!proxiable?(d) || c.proxied == d.proxied) }
      end
    end
  end
end
