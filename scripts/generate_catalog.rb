#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require 'uri'
require 'digest'

API_URL = ENV.fetch('OAM_METADATA_API_URL', 'https://api.openaerialmap.org/meta')
OUTPUT_PATH = ENV.fetch('STARC_OUTPUT_PATH', File.expand_path('../docs/catalog.json', __dir__))
CATALOG_URL = ENV.fetch('STARC_CATALOG_URL', 'https://optgeo.github.io/oam-starc/catalog.json')


def fetch_payload(url)
  uri = URI(url)
  response = Net::HTTP.get_response(uri)
  raise "Failed to fetch metadata API: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
end

def records_from(payload)
  return payload if payload.is_a?(Array)

  return payload['results'] if payload.is_a?(Hash) && payload['results'].is_a?(Array)

  []
end

def float_or_nil(value)
  Float(value)
rescue StandardError
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

  nil
end

def metadata_href(record)
  record['meta_uri'] || record['meta_url'] || record['metadata_url'] || record['metadata']
end

def imagery_href(record)
  record['url'] || record['image'] || record['imagery'] || record['tms'] || record['tile_url']
end

def datetime_for(record)
  raw = record['acquisition_start'] || record['capture_date'] || record['created_at'] || record['timestamp']
  return nil if raw.nil? || raw.to_s.strip.empty?

  Time.parse(raw.to_s).utc.iso8601
rescue ArgumentError
  nil
end

def item_from(record)
  coordinates = center_point(record)
  return nil unless coordinates

  lon, lat = coordinates
  id = record['uuid'] || record['id'] || record['_id'] || record['slug'] || "record-#{Digest::SHA256.hexdigest(record.to_json)[0, 12]}"

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
      'datetime' => datetime_for(record)
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

payload = fetch_payload(API_URL)
records = records_from(payload)
items = records.filter_map { |record| item_from(record) }
catalog = build_catalog(items)

File.write(OUTPUT_PATH, JSON.pretty_generate(catalog) + "\n")
puts "Wrote #{items.length} items to #{OUTPUT_PATH}"
