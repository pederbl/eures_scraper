class FoundJobOpening
  include Mongoid::Document

  field :source_id
  field :not_found_count, type: Integer, default: 0
  field :deleted_at, type: DateTime, default: nil
  field :job_opening_id, type: BSON::ObjectId  

  index :source_id
  index :deleted_at

  def delete
    self.deleted_at = Time.now
    self.save
    JobOpening.find(self.job_opening_id).update_attributes(deleted_at: Time.now) if self.job_opening_id
  end

  def source_url
    "http://ec.europa.eu/eures/eures-searchengine/servlet/ShowJvServlet?lg=EN&#{URI.escape(self.source_id)}" 
  end

end
