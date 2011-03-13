class JobOpening
  #BASE_URL = "http://ec2-46-137-5-1.eu-west-1.compute.amazonaws.com"
  include Mongoid::Document

  #after_save :push_to_base

  #def push_to_base
  #  job_openings = RestClient::Resource.new(BASE_URL)
  #  job_openings['job_openings'].post({ job_opening: self }.to_json, content_type: :json)
  #end

  before_create :create_slug

  field :slug

  index :slug, unique: true

  def create_slug
    slug = nil
    suffix = 0
    while slug.nil?
      slug = "#{title} #{employer[:name]}#{suffix == 0 ? "" : " #{suffix}"}".to_url
      if self.class.where(slug: slug).first.present?
        slug = nil
        suffix += 1 
      end
    end
    self.slug = slug
    puts slug
  end

end
