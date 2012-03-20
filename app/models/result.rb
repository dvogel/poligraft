class Result

  include MongoMapper::Document

  key :source_url, String
  key :source_title, String
  key :source_text, String
  key :source_format, String
  key :source_hash, String
  key :slug, String
  key :status, String
  key :contribution_count, Integer, :default => 0
  key :processed, Boolean, :default => false
  key :suppress_text, Boolean, :default => false
  timestamps!

  many :entities

  ensure_index :slug
  ensure_index :source_url

  validates_presence_of :source_title
  validates_presence_of :source_text
  validates_presence_of :source_format
  validates_presence_of :slug
  validates_presence_of :source_hash
  validates_uniqueness_of :slug

  before_validation :ensure_slug, :ensure_source_title_text, :ensure_hash
  before_create :set_status

  def source_content
    self.source_text.to_s
  end

  def ensure_slug
    return unless self.slug.blank?
    chars = ('a'..'z').to_a + ('A'..'Z').to_a + (1..9).to_a
    begin
      self.slug = chars.sort_by {rand}[0,4].join
    end while (Result.first(:slug => self.slug))
  end

  def ensure_source_title_text
    return unless self.source_format.blank?
    self.source_format = 'plain_text'
    self.source_title = self.source_content[0..30] + "..."
    if self.source_content.blank?
      raise "Must set source_url or source_content" if self.source_url.blank?
      self.source_text = ContentPlucker.pluck_from(self.source_url)
      self.source_title = ContentPlucker.pluck_title_from(self.source_url)
      self.source_format = 'html'
    end
  end

  def ensure_hash
    return unless self.source_hash.blank?
    unless self.source_content.blank?
      self.source_hash = Digest::MD5.hexdigest(self.source_content)
    end
  end

  def set_status
    self.status = "Text Plucked"
  end

  def process_entities
    TransparencyData.api_key = KEYS["sunlight"]
    TransparencyData.api_domain = KEYS["ie"] if KEYS["ie"]
    InboxInfluence.api_key = KEYS["sunlight"]
    results = InboxInfluence::Client.contextualize(self.source_content)
    if results
      extract_entities(results)
      find_contributors
    end
    self.source_text = '' if self.suppress_text == true
    self.save
  end

  def extract_entities(results)
    names_to_suppress = ["white house", "house", "senate", "congress", "assembly", "supreme court",
                         "legislature", "state senate", "administration", "obama administration",
                         "republicans", "republican party", "democrats", "democratic party"]

    results.each do |result|
      # only keep proper noun matches
      matches = result.matched_text.keep_if {|match| match =~ /^[A-Z0-9]/ }
      next unless matches.any?

      puts result.entity_data.name
      puts matches
      puts '---'

      campfin = result.entity_data.campaign_finance rescue {}
      lobbying = result.entity_data.lobbying rescue {}
      amt_given = campfin.recipient_breakdown.dem + campfin.recipient_breakdown.rep rescue 0.0
      amt_received = campfin.contributor_type_breakdown.pac + campfin.contributor_type_breakdown.individual rescue 0.0
      amt_received += campfin.contributor_local_breakdown.in_state + campfin.contributor_local_breakdown.out_of_state rescue 0.0
      total_amt = amt_given + amt_received

      unless names_to_suppress.include?(result.entity_data.name.downcase)
        entity = Entity.new({:tdata_name => result.entity_data.name,
                             :tdata_type => result.entity_data.type,
                             :tdata_id => result.entity_data.id,
                             :tdata_slug => result.entity_data.slug,
                             :tdata_count => total_amt,
                             :matched_names => matches
                             })

        if (local_breakdown = campfin.contributor_local_breakdown)
          breakdown = Hashie::Mash.new({:in_state_amount => local_breakdown.in_state, :out_of_state_amount => local_breakdown.out_of_state})
          add_breakdown(breakdown, entity, :first => 'in_state', :second => 'out_of_state', :type => 'contributor')
        end

        if (contributor_type_breakdown = campfin.contributor_type_breakdown)
          breakdown = Hashie::Mash.new({:pac_amount => contributor_type_breakdown.pac, :individual_amount => contributor_type_breakdown.individual})
          add_breakdown(breakdown, entity, :first => 'individual', :second => 'pac', :type => 'contributor')
        end

        if (recipient_breakdown = campfin.recipient_breakdown)
          breakdown = Hashie::Mash.new({:dem_amount => recipient_breakdown.dem, :rep_amount => recipient_breakdown.rep})
          add_breakdown(breakdown, entity, :first => 'dem', :second => 'rep', :type => 'recipient')
        end

        lobbying.clients.each do |client|
          entity.lobbying_clients << client.name
        end if lobbying.clients.present?

        lobbying.top_issues.each do |issue|
          entity.lobbying_issues << issue.name
        end if lobbying.top_issues.present?

        campfin.top_industries.each do |industry|
          if entity.top_industries.length < 5 &&
             industry.name != 'Other' &&
             industry.name !~ /(unknown|listed or discovered)$/i &&
             industry.name != 'Administrative Use' &&
             entity.top_industries.exclude?(industry.name)
            entity.top_industries << industry.name
          end
        end if campfin.top_industries.present?

        self.entities << entity
      end
    end
    self.status = "Entities Linked"
    self.save
  end

  def find_contributors
    hydra = Typhoeus::Hydra.new(:max_concurrency => 1)
    tdata = TransparencyData::Client.new(hydra)
    self.entities.each do |recipient|
      if recipient.tdata_type == 'politician'
        self.entities.each do |contributor|
          unless contributor.tdata_id.blank? || contributor.tdata_type == 'politician'
            Rails.logger.info "recipient: #{recipient.tdata_id} | contributor: #{contributor.tdata_id}"
            tdata.recipient_contributor_summary(recipient.tdata_id, contributor.tdata_id) do |summary, error|
              if error
                Rails.logger.info "Error in find_contributors: #{error}"
              elsif summary.amount.to_i > 0
                recipient.contributors << Contributor.new(:tdata_name => summary.contributor_name,
                                                          :matched_names => contributor.matched_names,
                                                          :amount => summary.amount,
                                                          :tdata_id => contributor.tdata_id,
                                                          :tdata_type => contributor.tdata_type,
                                                          :tdata_slug => contributor.tdata_slug)
                self.contribution_count += 1
              end
            end
          end # unless contributor.tdata_id.blank?
        end # if self.entities.each do |contributor|
        recipient.save
      end # if recipient.tdata_type
    end # self.entities.each do |recipient|
    hydra.run
    self.status = "Contributors Identified"
    self.processed = true
    self.save
  end

  def add_breakdown(breakdown, entity, params)
    first = breakdown.send("#{params[:first]}_amount").to_i
    second = breakdown.send("#{params[:second]}_amount").to_i
    sum = first + second
    sum = 1 if sum == 0
    entity.send("#{params[:type]}_breakdown")[params[:first]] = (first * 100) / sum
    entity.send("#{params[:type]}_breakdown")[params[:second]] = (second * 100) / sum
    entity.save
  end

  handle_asynchronously :process_entities

end
