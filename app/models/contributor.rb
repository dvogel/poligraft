class Contributor
  include MongoMapper::EmbeddedDocument
  
  key :tdata_name, String
  key :extracted_name, String
  key :amount, Integer
  key :tdata_id, String
  key :tdata_type, String
  key :tdata_slug, String
    
end