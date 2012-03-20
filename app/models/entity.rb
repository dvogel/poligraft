class Entity
  include MongoMapper::EmbeddedDocument

  key :tdata_id, String
  key :matched_names, Array
  key :tdata_name, String
  key :tdata_type, String
  key :tdata_slug, String
  key :tdata_count, Integer
  key :contributor_breakdown, Hash
  key :recipient_breakdown, Hash
  key :top_industries, Array
  key :lobbying_clients, Array
  key :lobbying_issues, Array

  many :contributors
end