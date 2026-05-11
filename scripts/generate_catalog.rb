#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require 'uri'
require 'digest'

def positive_integer_or_nil(value)
  integer = Integer(value)
  integer.positive? ? integer : nil
rescue ArgumentError, TypeError
  nil
end

API_URL = ENV.fetch('OAM_METADATA_API_URL', 'https://api.openaerialmap.org/meta')
OUTPUT_PATH = ENV.fetch('STARC_OUTPUT_PATH', File.expand_path('../docs/catalog.json', __dir__))
CATALOG_URL = ENV.fetch('STARC_CATALOG_URL', 'https://optgeo.github.io/oam-starc/catalog.json')
API_LIMIT = positive_integer_or_nil(ENV['OAM_METADATA_API_LIMIT']) || 100
HASH_ID_LENGTH = 16


def fetch_payload(url, page:, limit:)
  uri = URI(url)
  query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key == 'page' || key == 'limit' }
  query << ['page', page.to_s]
  query << ['limit', limit.to_s]
  uri.query = URI.encode_www_form(query)

  puts "Fetching page #{page} with limit #{limit}"
  response = Net::HTTP.get_response(uri)
  raise "Failed to fetch metadata API page #{page}: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
rescue JSON::ParserError => e
  raise e.class, "Failed to parse metadata API response for page #{page}: #{e.message}", e.backtrace
end

def records_from(payload)
  return payload if payload.is_a?(Array)

  return payload['results'] if payload.is_a?(Hash) && payload['results'].is_a?(Array)

  []
end

def metadata_from(payload)
  return payload['meta'] if payload.is_a?(Hash) && payload['meta'].is_a?(Hash)

  {}
end

def fetch_all_records(url, limit:)
  records = []
  page = 1
  total_pages = nil
  response_limit = limit

  loop do
    payload = fetch_payload(url, page: page, limit: response_limit)
    page_records = records_from(payload)
    meta = metadata_from(payload)
    found = positive_integer_or_nil(meta['found'])
    response_limit = positive_integer_or_nil(meta['limit']) || response_limit
    reported_page = positive_integer_or_nil(meta['page'])
    log_page = reported_page || page

    if total_pages.nil? && found && response_limit
      total_pages = (found.to_f / response_limit).ceil
      puts "Pagination metadata: found=#{found}, limit=#{response_limit}, total_pages=#{total_pages}"
    end

    records.concat(page_records)
    puts "Fetched page #{log_page}: #{page_records.length} records (accumulated #{records.length})"

    reached_last_page = total_pages && page >= total_pages
    reached_partial_page = total_pages.nil? && !page_records.empty? && page_records.length < response_limit
    break if page_records.empty? || reached_last_page || reached_partial_page

    page += 1
  end

  records
end

def stable_record_id(record)
  return nil unless record.is_a?(Hash)

  candidate = record['uuid'] || record['id'] || record['_id'] || record['slug']
  return nil if candidate.nil? || candidate.to_s.strip.empty?

  candidate.to_s
end

def deduplicate_records(records)
  seen = {}
  duplicates = 0

  deduped = records.filter_map do |record|
    id = stable_record_id(record)
    if id
      if seen[id]
        duplicates += 1
        next
      end
      seen[id] = true
    end
    record
  end

  puts "Deduplicated #{duplicates} records by stable identifier" if duplicates.positive?
  deduped
end

def float_or_nil(value)
  Float(value)
rescue StandardError
  nil
end

def coordinates_from_bbox(bbox)
  return nil unless bbox.is_a?(Array) && bbox.size >= 4

  min_lon = float_or_nil(bbox[0])
  min_lat = float_or_nil(bbox[1])
  max_lon = float_or_nil(bbox[2])
  max_lat = float_or_nil(bbox[3])
  return nil unless min_lon && min_lat && max_lon && max_lat

  [
    (min_lon + max_lon) / 2.0,
    (min_lat + max_lat) / 2.0
  ]
end

def coordinates_from_geojson(geojson)
  return nil unless geojson.is_a?(Hash)

  type = geojson['type']
  coordinates = geojson['coordinates']

  case type
  when 'Point'
    return nil unless coordinates.is_a?(Array) && coordinates.size >= 2

    lon = float_or_nil(coordinates[0])
    lat = float_or_nil(coordinates[1])
    return [lon, lat] if lon && lat
  when 'Polygon'
    ring = coordinates&.first
    return nil unless ring.is_a?(Array) && !ring.empty?

    points = ring.filter_map do |point|
      next unless point.is_a?(Array) && point.size >= 2

      lon = float_or_nil(point[0])
      lat = float_or_nil(point[1])
      [lon, lat] if lon && lat
    end
    return nil if points.empty?

    lons = points.map(&:first)
    lats = points.map(&:last)
    return [
      (lons.min + lons.max) / 2.0,
      (lats.min + lats.max) / 2.0
    ]
  end

  nil
end

def center_point(record)
  center = record['center']
  if center.is_a?(Hash)
    lon = float_or_nil(center['lon'] || center['lng'] || center['longitude'])
    lat = float_or_nil(center['lat'] || center['latitude'])
    return [lon, lat] if lon && lat

    coordinates = center['coordinates']
    if coordinates.is_a?(Array) && coordinates.size >= 2
      lon = float_or_nil(coordinates[0])
      lat = float_or_nil(coordinates[1])
      return [lon, lat] if lon && lat
    end
  elsif center.is_a?(Array) && center.size >= 2
    lon = float_or_nil(center[0])
    lat = float_or_nil(center[1])
    return [lon, lat] if lon && lat
  end

  lon = float_or_nil(record['lon'] || record['lng'] || record['longitude'])
  lat = float_or_nil(record['lat'] || record['latitude'])
  return [lon, lat] if lon && lat

  coordinates_from_bbox(record['bbox']) || coordinates_from_geojson(record['geojson'])
end

def metadata_href(record)
  record['meta_uri'] || record['meta_url'] || record['metadata_url'] || record['metadata']
end

def imagery_href(record)
  properties = record['properties']
  return properties['tms'] if properties.is_a?(Hash) && properties['tms']

  record['url'] || record['image'] || record['imagery'] || record['tms'] || record['tile_url']
end

def datetime_for(record)
  raw = record['acquisition_start'] || record['capture_date'] || record['created_at'] || record['timestamp']
  return nil if raw.nil? || raw.to_s.strip.empty?

  Time.parse(raw.to_s).utc.iso8601
rescue ArgumentError
  nil
end

def provider_for(record)
  value = record['provider'] || record.dig('properties', 'provider')
  return nil if value.nil?
  if value.is_a?(Hash)
    candidate = value['name'] || value['title'] || value['id']
    return candidate if candidate.is_a?(String)
    return candidate.to_s if candidate.is_a?(Numeric)

    return nil
  end

  value
end

def platform_for(record)
  record['platform'] || record.dig('properties', 'platform')
end

def uploaded_at_for(record)
  raw = record['uploaded_at'] || record.dig('properties', 'uploaded_at')
  return nil if raw.nil? || raw.to_s.strip.empty?

  Time.parse(raw.to_s).utc.iso8601
rescue ArgumentError
  raw.to_s
end

def item_from(record)
  return nil unless record.is_a?(Hash)

  coordinates = center_point(record)
  return nil unless coordinates

  lon, lat = coordinates
  id = stable_record_id(record) || "record-#{Digest::SHA256.hexdigest(record.to_json)[0, HASH_ID_LENGTH]}"

  item = {
    'type' => 'Feature',
    'stac_version' => '1.0.0',
    'stac_extensions' => [],
    'id' => id.to_s,
    'geometry' => {
      'type' => 'Point',
      'coordinates' => [lon, lat]
    },
    'bbox' => [lon, lat, lon, lat],
    'properties' => {
      'title' => record['title'] || record['name'],
      'description' => record['description'],
      'datetime' => datetime_for(record),
      'provider' => provider_for(record),
      'platform' => platform_for(record),
      'uploaded_at' => uploaded_at_for(record)
    },
    'assets' => {}
  }

  item['assets']['metadata'] = {
    'href' => metadata_href(record),
    'type' => 'application/json',
    'title' => 'OpenAerialMap metadata'
  } if metadata_href(record)

  item['assets']['imagery'] = {
    'href' => imagery_href(record),
    'title' => 'OpenAerialMap imagery'
  } if imagery_href(record)

  item['links'] = [
    {
      'rel' => 'self',
      'href' => "#{CATALOG_URL}#item-#{id}"
    }
  ]

  item
end

def build_catalog(items)
  {
    'stac_version' => '1.0.0',
    'type' => 'Catalog',
    'id' => 'oam-starc',
    'title' => 'OAM STARC (SpatioTemporal Asset Resource Catalog)',
    'description' => 'A derived, unofficial STARC generated from OpenAerialMap metadata API.',
    'links' => [
      {
        'rel' => 'self',
        'href' => CATALOG_URL,
        'type' => 'application/json'
      },
      {
        'rel' => 'root',
        'href' => CATALOG_URL,
        'type' => 'application/json'
      }
    ],
    'items' => items
  }
end

records = deduplicate_records(fetch_all_records(API_URL, limit: API_LIMIT))
items = records.filter_map { |record| item_from(record) }
catalog = build_catalog(items)

File.write(OUTPUT_PATH, JSON.pretty_generate(catalog) + "\n")
puts "Wrote #{items.length} items to #{OUTPUT_PATH}"
