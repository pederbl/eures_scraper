require JobOpeningModels::JobOpeningModelsEngine.root.join("app", "models", "job_opening")
class JobOpening
  #BASE_URL = "http://ec2-46-137-5-1.eu-west-1.compute.amazonaws.com"
  include Mongoid::Document
  include Mongoid::TranslatedStrings

  before_create :create_slug

  field :slug
  field :sphinx_id, type: Integer

  index :slug, unique: true

  validates :publish_at, presence: true

  def create_slug
    slug = nil
    suffix = 0
    while slug.nil?
      slug = "#{self.t(:title)} #{employer.try(:name) ? " #{employer.name}" : ""} #{suffix == 0 ? "" : " #{suffix}"}".to_url
      if self.class.where(slug: slug).first.present?
        slug = nil
        suffix += 1 
      end
    end
    self.slug = slug
    puts slug
  end

  def delete
    update_attributes(deleted_at: Time.now) 
    if sphinx_id
      client = Riddle::Client.new
      client.update('job_openings', ["deleted_at"], { sphinx_id => [Time.now.to_i] })
      client.update('job_openings_delta', ["deleted_at"], { sphinx_id => [Time.now.to_i] })
    end
  end

end
