# encoding: utf-8

module EuresClient
  require 'open-uri'

  def self.get_html(url, error_text = nil)
    begin
      html = nil
      open(url) { |f| html = f.read }
      raise 'error_text' if error_text and html.include?(error_text)
      return html
    rescue => e
      puts e.message
      if _r ||= 0 and (_r += 1) < 20
        sleep _r * 1
        retry
      end
      return nil
    end
  end
  
  def self.get_nokogiri_body(url, error_text = nil)
    html = get_html(url, error_text)
    return nil unless html
    html.gsub!(/(\r?\n|\t)/, "")
    html.gsub!(/(.*<th colspan="4">Description:<\/th> *<\/tr> *<tr> *<td colspan="4" class="JRTitle">)(.*?)( *<\/td> *<\/tr> *<tr> *<td colspan="\d" class="JRTitle">.*)/) { |s| last_html = $3; "#{$1}#{$2.gsub(/<\/?[^>]*>/, " ").gsub(/<.*$/, "")}#{last_html}" }
    Nokogiri::HTML(html, nil, "utf-8")
  end

  class Finder

    def self.list_url(attrs)
      "http://ec.europa.eu/eures/eures-searchengine/servlet/BrowseCountryJVsServlet?lg=EN&multipleCountries=AT-RD1000&date=01/01/1975&title=&durex=&exp=&serviceUri=browse&qual=&pageSize=10&page=1&startIndexes=0-1o1-1o2-1I&totalCount=14&isco=#{attrs[:isco]}&country=#{attrs[:country]}&multipleRegions=#{attrs[:region]}"
    end

    def self.run
      @logger = Logger.new(Rails.root.join("log", "finder.log"))
      start_time = Time.now
    
      (0..2).each { |i| 
        FoundJobOpening.where(not_found_count: i, deleted_at: nil).update_all(not_found_count: i + 1) 
      }
    
      listing_urls = {}
    
      EuresClient::isco_codes.each { |code|
        @logger.info("#{code} #{Time.now}")
        next unless code.length == 3
        start_isco = Time.now
        EuresClient::locations.each { |country, regions|
          #@logger.info([country, regions].inspect)
          num_results = 0
          start_country = Time.now
          regions.each { |region|
            url = list_url(isco: code, country: country, region: region)
            while url.present?
              doc = EuresClient::get_nokogiri_body(url)
              break unless doc
              results = doc.css('.JResult')
              break unless results.present?
              num_results += results.length 

              results.each { |result|
                link = result.css('.JRTitle a').first
                onclick = link['onclick']
                source_id = onclick.scan(/ShowJvServlet\?[^']*'/).first.gsub('ShowJvServlet?lg=EN&', '')[0..-2]
                listing = FoundJobOpening.where(source_id: source_id).first
                #puts "\t\t\t\t#{listing ? 'Existing' : 'New'}"
                if listing
                  listing.update_attributes!(not_found_count: 0, deleted_at: nil)
                else
                  FoundJobOpening.create!(source_id: source_id)
                end
              }
          
              next_link = doc.xpath("//div[@class='prevNext']/p/a[.='Next page']").first
              url = next_link ? 'http://ec.europa.eu/eures/eures-searchengine/servlet' + next_link['href'][1..-1] : nil
            end
          }
          @logger.info("\t#{country} #{num_results} #{"%.0f" % (Time.now - start_country)}s")
        }
        @logger.info("\t#{"%.0f" % (Time.now - start_isco)}s")
      }
      #puts get_nokogiri_body(url).inspect
    end
  end

  class Deleter
    def self.run
      @logger.info("start deleting not_found job openings: #{Time.now}")
      FoundJobOpening.where(:not_found_count.gt => 2).map(&:id).each { |id| FoundJobOpening.find(id).delete }
      @logger.info("deleting not_found job openings done: #{Time.now}")
    end
  end

  class Creator
    def self.run
      @logger = Logger.new(Rails.root.join("log", "creator.log"))
      found_job_openings = FoundJobOpening.where(job_opening_id: nil, deleted_at: nil)
      ids = FoundJobOpening.where(:job_opening_id => nil, deleted_at: nil).map { |d| d.id }
      @logger.info("count: #{ids.count}")
      ids.each_with_index { |id, idx|
        @logger.info("#{idx + 1}/#{ids.count}")
        found_job_opening = FoundJobOpening.where(_id: id).first
        attrs = EuresClient::get_job_info(found_job_opening)
        if attrs.nil?
          @logger.info("delete")
          found_job_opening.delete
          next 
        end
        attrs[:updated_at] = Time.now
        job_opening = JobOpening.create!(attrs)
        found_job_opening.job_opening_id = job_opening.id
        found_job_opening.synced_at = Time.now
        found_job_opening.save!
        @logger.info(job_opening.slug)
      }
    end
  end

  class Updater 
    def self.run
      @logger = Logger.new(Rails.root.join("log", "updater.log"))
      ids = []
      skip = 0
      limit = 10000
      loop {
        new_ids = FoundJobOpening.where(:job_opening_id.ne => nil, deleted_at: nil).asc(:synced_at).skip(skip).limit(limit).map(&:id)
        break if new_ids.blank?
        ids += new_ids
        skip += limit
        @logger.info(skip.to_s)
      }
      ids.each_with_index { |id, idx|
        @logger.info("\n#{idx}/#{ids.count}")
        sync(FoundJobOpening.where(_id: id).first)
      }
    end

    def self.sync_job(slug)
      @logger = Logger.new(STDOUT)
      job_opening = JobOpening.where(slug: slug).first
      found_job_opening = FoundJobOpening.where(job_opening_id: job_opening.id).first
      sync(found_job_opening)
    end

    def self.sync(found_job_opening)
      @logger.info("synced_at: #{found_job_opening.synced_at}")
      attrs = EuresClient::get_job_info(found_job_opening)
      if attrs.nil?
        found_job_opening.delete
        @logger.info("delete: #{found_job_opening.source_url}")
      else
        job = JobOpening.where(_id: found_job_opening.job_opening_id).first

        # don't update publish_at: job.publish_at = attrs[:publish_at]
        job.publish_until = attrs[:publish_until]
        job.title = attrs[:title]
        job.body = attrs[:body]
        job.num_positions = attrs[:num_positions]
        job.primary_language = attrs[:primary_language]
        job.job_category_tags = attrs[:job_category_tags]
        job.isco = attrs[:isco]
        job.nace = attrs[:nace]
        job.job_title = attrs[:job_title]
        job.job_type = attrs[:job_type]

        h = attrs[:employer]
        if h.blank?
          job.employer = nil
        else
          d = job.employer || Employer.new
          d.name = h[:name]
          d.national_id = h[:national_id]
          d.email = h[:email]
          d.phone = h[:phone]
          d.fax = h[:fax]
          d.website = h[:website]
          d.mail_address = h[:mail_address]
          d.visit_address = h[:visit_address]
          d.text = h[:text]
        end

        h = attrs[:requirements]
        if h.blank?
          job.requirements = nil
        else
          d = job.requirements || Requirements.new
          d.drivers_license = h[:drivers_license] 
          d.education = h[:education] 
          d.experience = h[:experience] 
          d.own_car = h[:own_car] 
          d.minimum_age = h[:minimum_age] 
          d.maximum_age = h[:maximum_age] 
          d.text = h[:text] 
          d.languages = h[:language] 
        end

        h = attrs[:worktime]
        if h.blank?
          job.worktime = nil
        else
          d = job.worktime || Worktime.new
          d.type = h[:type] 
          d.hours_per_week = h[:hours_per_week] 
          d.text = h[:text] 
        end
        
        h = attrs[:duration]
        if h.blank?
          job.duration = nil
        else
          d = job.duration || Duration.new
          d.length = h[:length] 
          d.starts_on = h[:starts_on] 
          d.ends_on = h[:ends_on] 
          d.sub = h[:sub] 
          d.text = h[:text] 
        end
        
        h = attrs[:salary]
        if h.blank?
          job.salary = nil
        else
          d = job.salary || Salary.new
          d.minimum = h[:minimum] 
          d.maximum = h[:maximum] 
          d.currency = h[:currency] 
          d.period = h[:period] 
          d.accommodation = h[:accommodation] 
          d.meals = h[:meals] 
          d.travel_expenses = h[:travel_expenses] 
          d.relocation = h[:relocation] 
          d.text = h[:text] 
        end
        
        h = attrs[:application]
        if h.blank?
          job.application = nil
        else
          d = job.application || Application.new
          d.contact = h[:contact] 
          d.email = h[:email] 
          d.mail = h[:mail] 
          d.phone = h[:phone] 
          d.url = h[:url] 
          d.reference = h[:reference] 
          d.deadline = h[:deadline] 
          d.text = h[:text] 
        end
        
        raise "no location" if attrs[:location].blank? 
        job.location ||= Location.new
        reset_fields(job.location, attrs[:location])
        
        job.contacts = attrs[:contacts]
        job.union_contacts = attrs[:union_contacts]

        job.save
      end
      found_job_opening.update_attributes(synced_at: Time.now)
    end
    
    def self.reset_fields(doc, attrs)
      doc.fields.keys.each { |k| doc.send("#{k}=", nil) }
      attrs.each { |k, v| doc.send("#{k}=", v) }
    end
  end

  def self.get_geonameid(attrs)
    raise attrs.inspect unless attrs[:country]
    
    geonameid = GeonamesLocation.search(
      country: attrs[:country],
      admin1: attrs[:region],
      admin2: attrs[:city]
    ).first.try(:geonameid)

    if geonameid.nil? and attrs[:city].present?
      geonameid = GeonamesLocation.search(
        country: attrs[:country],
        admin1: attrs[:region],
        admin3: attrs[:city]
      ).first.try(:geonameid)
    end

    if geonameid.nil? and (attrs[:region].present? or attrs[:city].present?)
      reduced_attrs = attrs.dup
      if attrs[:city].present? 
        reduced_attrs[:city] = nil
      else
        reduced_attrs[:region] = nil
      end
      puts "get_geonameid: #{attrs.inspect} => #{reduced_attrs.inspect}"
      geonameid = get_geonameid(reduced_attrs)
    end

    raise attrs.inspect if geonameid.nil?
    return geonameid
  end

  def self.get_job_info(found_job_opening)
    url = found_job_opening.source_url
    puts url
    doc = EuresClient::get_nokogiri_body(url)
    return nil if doc.nil?
    if doc.to_html.include?("There has been an error trying to show job vacancy")
      found_job_opening.delete
      return nil
    end
    return nil if doc.to_html.include?("The server containing job vacancy information is currently down. Please try again later.")
    info = doc.css(".JRdetails")
    raise doc.to_html if info.blank?
    language = 'x'
    attrs = {
      deleted_at: nil,
      source: "ec.europa.eu",
      source_id: found_job_opening.source_id,
      source_url: found_job_opening.source_url,
      primary_language: language,
      employer: {},
      requirements: { 
        languages: []
      },
      worktime: {},
      duration: {},
      salary: {},
      application: {},
      location: {},
      contacts: [],
      union_contacts: []
    }
    application_text = []
    salary_text = []
    requirements_text = []
    begin
      job = JobOpening.new
      
      current_title = nil
      current_subtitle = nil
      info.xpath("//tr").each { |row|
        row = Nokogiri::HTML(row.to_html, nil, "utf-8")
        new_current_title = if row.xpath("//td/strong[.='Summary']").first;   :summary
        elsif row.xpath("//td/strong[.='Geographical Information']").first;   :geographical_info
        elsif row.xpath("//td/strong[.='Salary / Contract']").first;          :salary_contract
        elsif row.xpath("//td/strong[.='Extras']").first;                     :extras
        elsif row.xpath("//td/strong[.='Requirements']").first;               :requirements
        elsif row.xpath("//td/strong[.='Employer']").first;                   :employer
        elsif row.xpath("//td/strong[.='How to apply']").first;               :application
        elsif row.xpath("//td/strong[.='Other Information']").first;          :other
        else  nil
        end
        if new_current_title
          current_title = new_current_title
          current_subtitle = nil
          next
        end


        new_current_subtitle = nil
        case current_title
        when :summary
          if row.xpath("//tr/th[.='Description:']").first
            new_current_subtitle = :description 
          end

        when :geographical_info

        when :salary_contract

        when :extras

        when :requirements

        when :employer

        when :application

        when :other

        else
          raise current_title
        end
        if new_current_subtitle
          current_subtitle = new_current_subtitle
          next
        end
        

        case current_title
        when :summary
          key = row.xpath("//tr/th").first
          key = key.content.strip[0..-2] if key
          value = row.xpath("//tr/td").first.try(:content).try(:strip)
          case current_subtitle
          when nil
            case key
            when nil
              next
            when "Title"
              if value.include?("Arbeitsort: ")
                attrs[:location][:city] = value.scan(/Arbeitsort: (.*)/).first.try(:first) rescue raise([url, value].inspect)
                value = value.gsub(/Arbeitsort: .*/, "").strip
              end
              attrs[:title] = { language => value }
            when "Required languages"
              value.split(",").each { |language|
                language, proficiency = language.gsub(/[()]/, "").split("-")

                language = parse_language(language)
                
                if language
                  proficiency = parse_proficiency(proficiency) rescue raise([proficiency, url].inspect)
                  attrs[:requirements][:languages] << LanguageRequirement.new(language: language, proficiency: proficiency)
                end
              }
            when "Starting Date"
              attrs[:duration][:starts_on] = Time.parse(value) rescue nil
            when "Ending date"
              attrs[:duration][:ends_on] = Time.parse(value) rescue nil
            else raise [key, url].inspect
            end
          when :description
            attrs[:body] = { language => parse_body(row.content.try(:strip)) }
          else 
            raise current_subtitle
          end

        when :geographical_info
          if row.xpath("//tr/th[.='Country:']").first
            country = row.xpath("//tr/td").first.content.strip
            if country.present? 
              attrs[:location][:country] = country_en_2_code(country)
              attrs[:location][:region] = row.xpath("//tr/td")[1].try(:content).try(:strip)
            end
          else
            next
          end

        when :salary_contract
          key = row.xpath("//tr/th").first
          next if key.nil?
          key = key.content.strip[0..-2] 
          value = row.xpath("//tr/td").first.content.try(:strip)
          case key
          when nil; next
          when "Contract type"
            duration, attrs[:worktime][:type] = case value
            when "unbefristet Arbeitsplatz (Vollzeit)"; ["PERMANENT", "FULL_TIME"]
            when "unbefristet Arbeitsplatz (Teilzeit)"; ["PERMANENT", "PART_TIME"]
            when "befristet Arbeitsplatz (Vollzeit)"; ["TEMPORARY", "FULL_TIME"]
            when "befristet Arbeitsplatz (Teilzeit)"; ["TEMPORARY", "PART_TIME"]
            when "Arbeitsplatz (Vollzeit)"; ["PERMANENT", "FULL_TIME"]
            when "Arbeitsplatz (Teilzeit)"; ["PERMANENT", "PART_TIME"]
            when "ΟΡΙΣΜΕΝΟΥ-ΠΛΗΡΗΣ"; ["PERMANENT", "FULL_TIME"]
            when "ΟΡΙΣΜΕΝΟΥ-ΜΕΡΙΚΗ"; ["PERMANENT", "PART_TIME"]
            when "ΑΟΡΙΣΤΟΥ-ΠΛΗΡΗΣ"; ["TEMPORARY", "FULL_TIME"]
            when "ΑΟΡΙΣΤΟΥ-ΜΕΡΙΚΗ"; ["TEMPORARY", "PART_TIME"]
            when "ΕΠΟΧΙΚΗ-ΠΛΗΡΗΣ"; ["TEMPORARY", "FULL_TIME"]
            when "ΕΠΟΧΙΚΗ-ΜΕΡΙΚΗ"; ["TEMPORARY", "PART_TIME"]
            when "P"; ["PERMANENT", nil]
            when "T"; ["TEMPORARY", nil]
            when "PF - Full-Time"; ["PERMANENT", "FULL_TIME"]
            when "PP - Part-Time"; ["PERMANENT", "PART_TIME"]
            when "TF - Full-Time"; ["PERMANENT", "FULL_TIME"]
            when "TP - Part-Time"; ["PERMANENT", "PART_TIME"]
            when "F - Full-Time"; [nil, "FULL_TIME"]
            when "P - Part-Time"; [nil, "PART_TIME"]
            when "To Be Advised - Full-Time"; [nil, "FULL_TIME"]
            when "To Be Advised - Part-Time"; [nil, "PART_TIME"]
            when "Other - Full-Time"; [nil, "FULL_TIME"]
            when "Other - Part-Time"; [nil, "PART_TIME"]
            when "Permanente - Completo"; ["PERMANENT", "FULL_TIME"]
            when "A Termo - Completo"; ["TEMPORARY", "FULL_TIME"]
            when "Permanente - Parcial"; ["PERMANENT", "PART_TIME"]
            when "A Termo - Parcial"; ["TEMPORARY", "PART_TIME"]
            when /Vinnumálastofnun .*/; [nil, nil]
            when "Traineeship"; attrs[:job_type] = "TRAINEE"; [nil, nil]
            when / \+ /; value.gsub("-", "_").split(" + ")
            else raise value
            end

            attrs[:duration][:length] = case duration
            when "PERMANENT"; -1
            when "TEMPORARY"; 0
            when nil; nil
            else
              raise [value, duration].inspect
            end
            
          when "Minimum salary"
            attrs[:salary][:minimum] = parse_salary(value, attrs) rescue raise([value, url].inspect)
          when "Maximum salary" 
            attrs[:salary][:maximum] = parse_salary(value, attrs) rescue raise([value, url].inspect)
          when "Salary currency"
            attrs[:salary][:currency] = case value.downcase
            when "pound (sterling)"; "GBP"
            when "pound sterling"; "GBP"
            when "euro"; "EUR"
            when "czech koruna"; "CZK"
            when "swiss franc"; "CHF"
            when "norwegian krone"; "NOK"
            when "iceland krona"; "ISK"
            when "swedish krona"; "SEK"
            when "leu"; "LEU"
            when "oth"; nil
            when "n/k"; nil
            when "******"; nil
            else raise value.inspect
            end
          when "Salary tax" #ignore
          when "Salary period"
            attrs[:salary][:period] = case value
            when "Hourly"; "H"
            when "Daily"; "D"
            when "Weekly"; "W"
            when "Monthly"; "M"
            when "Annually"; "Y"
            when "ΗΜΕΡΗΣΙΟ"; "D"
            when "ΜΗΝΙΑΙΟ"; "M"
            when "Ano"; "Y"
            when "Mês"; "M"
            when "Dia"; "D"
            when "Hora"; "H"
            when "C"; nil
            else 
              if url =~ /job.jobnet.dk/ 
                salary_text << value
              else
                raise value
              end
            end
          when "Hours per week"
            attrs[:worktime][:hours_per_week] = parse_value(value)
          else
            raise [key, url].inspect
          end
        when :extras
          row.xpath("//tr/th").each_with_index { |key, index|
            key = key.content.strip[0..-2]
            value = row.xpath("//tr/td")[index].content.try(:strip)
            case key
            when "Accommodation provided"
              attrs[:salary][:accommodation] = value == "Yes"
            when "Meals included"
              attrs[:salary][:meals] = value == "Yes"
            when "Travel expenses"
              attrs[:salary][:travel_expenses] = value == "Yes"
            when "Relocation covered"
              attrs[:salary][:relocation] = value == "Yes"
            else raise key.inspect
            end

          }

        when :requirements
          key = row.xpath("//tr/th").first.content.strip[0..-2]
          value = row.xpath("//tr/td").first.content.try(:strip)
          case key
          when "Education skills required"
            attrs[:requirements][:education] = { language => value }

          when "Professional qualifications required"
            attrs[:requirements][:experience] = value == "No" ? 0 : -1

          when "Experience required"
            attrs[:requirements][:experience] = case value
            when "Between 2 and 5 years"; 24
            when "More than 5 years"; 60
            when "None required"; 0
            when "Up to 1 year"; 0
            when "Up to 2 years"; 0
            when "Required"; -1
            when "See free text"; #ignore
            when "Δεν Απαιτείται"; 0
            when "1 Ετος"; 12
            when /\d{1,2} Ετη/; 
              value.scan(/(\d{1,2}) Ετη/).first.first.to_i * 12
            when /\d{1,2} months in sector:/
              requirements_text << "Experience required: #{value}"
              value.scan(/(\d{1,2}) months in sector:/).first.first.to_i
            else
              if url =~ /213.13.163.2\/euresWS-LocalPes-ver2/ # portugal
                requirements_text << value
                nil
              else
                raise value
              end
            end

          when "Driving license required"
            value.gsub!(/\.$/, '')
            attrs[:requirements][:drivers_license] = case value
            when "Yes"; ["B"]
            when "No"; []
            when /^((A1|A|A3|B|BE|C1|C1\+E|C|CE|D1|D|DE|G|T)(, ?|$)){1,}/; 
              arr = value.split(", ")
              arr.sort
            when "Motorcycle"; ["A"]
            when "Car with up to 8 passengers; lorry up to 3.5 tons"; ["B"]
            when "Car with 9 or more passengers"; ["C"] 
            when "Lorry over 3.5 tons"; ["C"]
            when /FS A1 Leichtkraftr.der/; ["A1"]
            when /FS A Motorr.der/; ["A"]
            when /FS B PKW\/Kleinbusse/; ["B"]
            when /FS BE PKW\/Kleinbusse/; ["BE"]
            when /FS C1 Leichte LKW/; ["C1"]
            when /FS C1E Leichte LKW/; ["C1E"]
            when /FS C Schwere LKW/; ["C"]
            when /FS CE Schwere LKW/; ["CE"]
            when /FS D1 Kleine Omnibusse/; ["D1"]
            when /FS D1E Kleine Omnibusse/; ["D1E"]
            when /FS D Omnibusse/; ["D"]
            when /FS DE Omnibusse/; ["DE"]
            when "Fahrerkarte"; ["B"]
            when "Voiture jusqu'à 8 passagers; camion jusqu'à 3,5 T"; ["B"]
            when "Véhicule de la classe B,C, ou D avec remorque"; ["BE", "CE", "DE"]
            when "Camion au dessus de 3,5 tonnes"; ["C"]
            when "ΜΟΤΟΣΙΚΛΕΤΑΣ ΕΩΣ 34 PS 25 KW Η 0,16 KW/KG"; ["A1"]
            when "ΜΟΤΟΣΙΚΛΕΤΑΣ ΕΩΣ 34 PS = 25 KW Η 0,16 KW/KG"; ["A1"]
            when "ΜΟΤΟΣΙΚΛΕΤΑ ΟΠΟΙΑΣΔΗΠΟΤΕ ΙΣΧΥΟΣ Η ΣΧΕΣΗΣ ΙΣΧΥΟΣ/ΒΑΡΟΥΣ"; ["A"]
            when "ΕΠΙΒΑΤΙΚΑ ΕΩΣ 9 ΘΕΣΕΙΣ ΚΑΙ ΦΟΡΤΗΓΑ ΕΩΣ 3500 KGR. ΜΙΚΤΟ + ΡΥΜΟΥΛΚ. ΕΩΣ 750 KGR"; ["BE"]
            when "ΦΟΡΤΗΓΑ ΕΩΣ 7500 KGR. ΜΙΚΤΟ + ΡΥΜΟΥΛΚ. ΕΩΣ 750 KGR"; ["C1"]
            when "ΦΟΡΤΗΓΑ ΑΠΟ 3501 KGR ΕΩΣ ΤΟ ΜΕΓΙΣΤΟ ΕΠΙΤΡΕΠΟΜΕΝΟ ΒΑΡΟΣ ΤΟΥ ΚΑΘΕ ΦΟΡΤΗΓΟΥ + ΡΥΜΟΥΛΚ. ΕΩΣ 750 KGR"; ["CE"]
            when "ΕΛΚΟΥΝ ΤΗΣ Δ ΚΑΤ. + ΡΥΜΟΥΛΚ. ΑΝΩ ΤΩΝ 750 KGR"; ["CE", "DE"]
            when "ΕΛΚΟΥΝ ΤΗΣ Β ΚΑΤ. + ΡΥΜΟΥΛ. ΑΝΩ ΤΩΝ 3500 KGR Η ΡΥΜΟΥΛΚ. ΒΑΡΥΤΕΡΟ ΤΟΥ ΕΛΚΟΝΤΟΣ ΚΕΝΟΥ"; ["CE", "DE"]
            when "ΕΛΚΟΥΝ ΤΗΣ Γ ΚΑΤ. + ΡΥΜΟΥΛΚ. ΑΝΩ ΤΩΝ 750 KGR"; ["CE"]
            when "Vehicle of either class B,C or D with trailer"; ["BE", "CE", "DE"]
            when "Gabelstaplerschein (Führerschein für Flurförderzeuge)"; requirements_text << value
            when "Gabelstaplerschein ("; requirements_text << value
            when /Fahrlehrerlaubnis/; requirements_text << value
            when "Führerschein Baumaschinen"; requirements_text << value
            when "Lokomotiv-/Triebfahrzeugführerschein Klasse 1"; requirements_text << value
            when "Lokomotiv-/Triebfahrzeugführerschein Klasse 2"; requirements_text << value
            when "FS T Große Traktoren"; requirements_text << value
            when "FS Fahrgastbeförderung (Taxen bzw. Krankenkraftwagen)"; requirements_text << value
            when "Lokomotiv-/Triebfahrzeugführerschein Klasse 3"; requirements_text << value
            when "FS L selbstf. land-, forstw. Arbeits- u. Zugmasch.(alt:FS 5)"; requirements_text << value
            when "FS M Moped, Mokick (alt: FS 4)"; requirements_text << value
            when "Gespannführerschein"; requirements_text << value
            when "FS S Dreiräd. Kleinkrafträder, vierräd. Leichtkraftfahrzeuge"; requirements_text << value
            when "FS Mofa und Krankenfahrstühle"; requirements_text << value
            when "Ligeiros"; requirements_text << value
            else raise [url, value].inspect
            end

          when "Minimum age"
            attrs[:requirements][:minimum_age] = value.to_i
            
          when "Maximum age"
            attrs[:requirements][:maximum_age] = value.to_i

          else raise key
          end

        when :employer
          value = row.xpath("//tr/td").first.content.try(:strip)
          key = row.xpath("//tr/th").first.content.strip[0..-2]
          key = case key
          when "Name";        :name
          when "Information"; :text
          when "Address";     :mail_address
          when "Phone";       :phone
          when "Fax";         :fax
          when "Email";       :email
          else raise key
          end
          if key == :text
            attrs[:employer][key] = { language => value }
          else
            attrs[:employer][key] = value
          end

        when :application
          if row.to_html.include?("&gt;Contact:&lt;")
            key = "Contact"
            value = row.xpath("//tr/th").first.content.strip
          else
            key = row.xpath("//tr/th").first.content.strip[0..-2]
            value = row.xpath("//tr/td").first.content.try(:strip)
          end
          case key
          when "How to apply"
            attrs[:application][:email] = value.scan(/\w*@\w*\.\w{2,6}/).first
            attrs[:application][:url] = value.scan(/(http:\/\/[^ ]*|www\.[^ ]*\.\w{2,6}\/[^ ]*)/).first.try(:first)
            application_text << value
          when "Contact"
            attrs[:application][:contact] = value
          when "Last date for application"
            attrs[:application][:deadline] = Time.parse(value) rescue nil
          else raise key.inspect
          end

        when :other
          row.xpath("//tr/th").each_with_index { |key, index|
            key = key.content.strip[0..-2]
            value = row.xpath("//tr/td")[index].content.try(:strip)
            case key
            when "Date published"
              published_at = Time.parse(value)
              published_at = Time.now if published_at.to_date.today?
              attrs[:publish_at] = published_at 
              attrs[:publish_at] = Time.now if Time.now < attrs[:publish_at]
            when "Nace code"
              attrs[:nace] = value
            when "ISCO code"
              attrs[:isco] = value.gsub(/0+$/, "")
            when "Last Modification Date"; #ignore
            when "National reference";     # ignore
            when "Eures reference"; # ignore
            when "Number of posts"
              attrs[:num_positions] = value.to_i

            else raise key.inspect
            end

          }

        else
          raise current_title
        end

        current_subtitle = nil
        
      }

      
    rescue => e
      raise e
      #raise [e.message, found_job_opening.source_url, doc.to_html].inspect
    end

    return nil unless attrs[:location][:country].present?
    attrs[:location][:geonameid] = get_geonameid(attrs[:location])

    attrs[:application][:text] = { language => application_text.join("\n") } if application_text.present?
    attrs[:salary][:text] = { language => salary_text.join("\n") } if salary_text.present?
    attrs[:requirements][:text] = { language => requirements_text.join("\n") } if requirements_text.present?

    attrs[:publish_at] = Time.now #unless attrs[:publish_at]
    #return nil if attrs[:publish_at] < 120.days.ago

    return attrs.with_indifferent_access 
  end

  def self.parse_body(value)
    #Swedish jobs are misformated in this way. tradeoff: this will screw up First.Last@example.com.
    value.gsub(/(\w[.?!;])(\w)/) { |s| a = $1; b = $2; (a == a.downcase && b == b.upcase && b =~ /\D/) ? "#{a}\n\n#{b}" : s } 
  end

  def self.parse_language(value)
    case value.strip.downcase
    when /(pt)/; value.strip.downcase
    when "czech"; "cs"
    when "deutsch"; "de"
    when "dutch"; "nl"
    when "english"; "en"
    when "englisch"; "en"
    when "french"; "fr"
    when "german"; "de"
    when "italian"; "it"
    when "português"; "pt"
    when "polish"; "pl"
    when "romanian"; "ro"
    when "russisch"; "ru"
    when "spanish"; "es"
    when "ΑΓΓΛΙΚΑ"; "en"
    when "other"; nil
    when "**"; nil
    else raise value
    end
  end

  def self.parse_proficiency(value)
    return nil if value.nil?

    case value.strip.downcase
    when "elementary"; 1
    when "basic"; 2
    when "good"; 3
    when "fair"; 3
    when "working knowledge"; 3
    when "very good"; 4
    when "fluent"; 4
    when "mother tongue"; 5

    when "grundkenntnisse"; 2
    when "gut"; 3
    when "erweiterte kenntnisse"; 4
    when "muttersprache"; 5
    when "zwingend erforderlich"; nil
    when "verhandlungssicher"; nil

    else raise value 
    end
  end

  def self.parse_value(value)
    amount = value.dup
    amount.gsub!(" ", "")
    amount.gsub!(/[,.]\d{3}/) { |s| s[1..-1] }
    amount.gsub!(/[,]\d{2}/) { |s| s.gsub(",", ".") }
    amount.to_f
  end

  def self.parse_salary(value, attrs)
    value = value.strip
    salary = case value.downcase
    when /\A[+-]?[\d,]+?(\.\d+)?\Z/; parse_value(value)
    when /and pound;\d+ and.../; value.scan(/and pound;(\d+) and.../).first.first.to_f
    when /and pound;\d+\/annum up to and.../
      attrs[:salary][:period] = "Y"
      value.scan(/and pound;(\d+)\/annum up to and.../i).first.first.to_f
    when /gbp \d+ - gbp \d+ per hour/
      attrs[:salary][:period] = "H"
      min, max = value.downcase.scan(/gbp (\d+) - gbp (\d+) per hour/).first
      attrs[:salary][:maximum] = max.to_f
      min.to_f
    when "exceeds nat min wage"; 
      attrs[:salary][:text] = value
      nil

    when "n/a"; nil
    when "please contact us for more information"; nil
    when "nach verhandlung"; nil
    when "n.v."; nil
    else 
      attrs[:salary][:text] = value
      nil
    end
    salary = nil if salary == 0.0
    return salary
  end


  def self.isco_codes
    return @isco_codes if @isco_codes
    
    codes = []
    codes[0]="11 ^ Legislators and senior officials";
    codes[1]="111 ^ Legislators";
    codes[2]="1120 ^ Senior government officials";
    codes[3]="113 ^ Traditional chiefs and heads of villages";
    codes[4]="1130 ^ Traditional chiefs and heads of villages";
    codes[5]="114 ^ Senior officials of special-interest organisations";
    codes[6]="1141 ^ Senior officials of political-party organisations";
    codes[7]="1142 ^ Senior officials of employers', workers' and other economic-interest organisations";
    codes[8]="1143 ^ Senior officials of humanitarian and other special-interest organisations";
    codes[9]="12 ^ Senior managers";
    codes[10]="121 ^ Directors and chief executives";
    codes[11]="1210 ^ Directors and chief executives";
    codes[12]="122 ^ Production and operations department managers";
    codes[13]="1221 ^ Production and operations department managers in agriculture, hunting forestry and fishing";
    codes[14]="1222 ^ Production and operations department managers in manufacturing";
    codes[15]="1223 ^ Production and operations department managers in construction";
    codes[16]="1224 ^ Production and operations department managers in wholesale and retail trade";
    codes[17]="1225 ^ Production and operations department managers in restaurants and hotels";
    codes[18]="1226 ^ Production and operations department managers in transport, storage and communications";
    codes[19]="1227 ^ Production and operations department managers in business services";
    codes[20]="1228 ^ Production and operations department managers in personal care, cleaning and related services";
    codes[21]="1229 ^ Production and operations department managers not elsewhere classified";
    codes[22]="123 ^ Other department managers";
    codes[23]="1231 ^ Finance and administration department managers";
    codes[24]="1232 ^ Personnel and industrial relations department managers";
    codes[25]="1233 ^ Sales and marketing department managers";
    codes[26]="1234 ^ Advertising and public relations department managers";
    codes[27]="1235 ^ Supply and distribution department managers";
    codes[28]="1236 ^ Computing services department managers";
    codes[29]="1237 ^ Research and development department managers";
    codes[30]="1239 ^ Other department managers not elsewhere classified";
    codes[31]="13 ^ General managers";
    codes[32]="131 ^ General managers";
    codes[33]="1311 ^ General managers in agriculture. hunting forestry and fishing";
    codes[34]="1312 ^ General managers in manufacturing";
    codes[35]="1313 ^ General managers in construction";
    codes[36]="1314 ^ General managers in wholesale and retail trade";
    codes[37]="1315 ^ General managers of restaurants and hotels";
    codes[38]="1316 ^ General managers in transport storage and communications";
    codes[39]="1317 ^ General managers of business services";
    codes[40]="1318 ^ General managers in personal care, cleaning and related services";
    codes[41]="1319 ^ General managers not elsewhere classified";
    codes[42]="21 ^ Computing, engineering and science professionals";
    codes[43]="211 ^ Physicists, chemists and related professionals";
    codes[44]="2111 ^ Physicists and astronomers";
    codes[45]="2112 ^ Meteorologists";
    codes[46]="2113 ^ Chemists";
    codes[47]="2114 ^ Geologists and geophysicists";
    codes[48]="212 ^ Mathematicians, statisticians and related professionals";
    codes[49]="2121 ^ Mathematicians and related professionals";
    codes[50]="2122 ^ Statisticians";
    codes[51]="213 ^ Computing professionals";
    codes[52]="2131 ^ Computer systems designers and analysts";
    codes[53]="2132 ^ Computer programmers";
    codes[54]="2139 ^ Computing professionals not elsewhere classified";
    codes[55]="214 ^ Architects, engineers and related professionals";
    codes[56]="2141 ^ Architects. town and traffic planners";
    codes[57]="2142 ^ Civil engineers";
    codes[58]="2143 ^ Electrical engineers";
    codes[59]="2144 ^ Electronics and telecommunications engineers";
    codes[60]="2145 ^ Mechanical engineers";
    codes[61]="2146 ^ Chemical engineers";
    codes[62]="2147 ^ Mining engineers. metallurgists and related professionals";
    codes[63]="2148 ^ Cartographers and surveyors";
    codes[64]="2149 ^ Architects. engineers and related professionals not elsewhere classified";
    codes[65]="22 ^ Healthcare and life science professionals";
    codes[66]="221 ^ Life science professionals";
    codes[67]="2211 ^ Biologists, botanists, zoologists and related professionals";
    codes[68]="2212 ^ Pharmacologists. pathologists and related professionals";
    codes[69]="2213 ^ Agronomists and related professionals";
    codes[70]="222 ^ Health professionals (except nursing)";
    codes[71]="2221 ^ Medical doctors";
    codes[72]="2222 ^ Dentists";
    codes[73]="2223 ^ Veterinarians";
    codes[74]="2224 ^ Pharmacists";
    codes[75]="2229 ^ Health professionals (except nursing) not elsewhere classified";
    codes[76]="223 ^ Nursing and midwifery professionals";
    codes[77]="2230 ^ Nursing and midwifery professionals";
    codes[78]="23 ^ Teaching professionals";
    codes[79]="231 ^ College, university and higher education teaching professionals";
    codes[80]="2310 ^ College, university and higher education teaching professionals";
    codes[81]="232 ^ Secondary education teaching professionals";
    codes[82]="2320 ^ Secondary education teaching professionals";
    codes[83]="233 ^ Primary and pre-primary education teaching professionals";
    codes[84]="2331 ^ Primary education teaching professionals";
    codes[85]="2332 ^ Pre-primary education teaching professional";
    codes[86]="234 ^ Special education teaching professionals";
    codes[87]="2340 ^ Special education teaching professionals";
    codes[88]="235 ^ Other teaching professionals";
    codes[89]="2351 ^ Education methods specialists";
    codes[90]="2352 ^ School inspectors";
    codes[91]="2359 ^ Other teaching professionals not elsewhere classified";
    codes[92]="24 ^ Accounting, legal, social science and artistic professionals";
    codes[93]="241 ^ Business professionals";
    codes[94]="2411 ^ Accountants";
    codes[95]="2412 ^ Personnel and careers professionals";
    codes[96]="2419 ^ Business professionals not elsewhere classified";
    codes[97]="242 ^ Legal professionals";
    codes[98]="2421 ^ Lawyers";
    codes[99]="2422 ^ Judges";
    codes[100]="2429 ^ Legal professionals not elsewhere classified";
    codes[101]="243 ^ Archivists, librarians and related information professionals";
    codes[102]="2431 ^ Archivists and curators";
    codes[103]="2432 ^ Librarians and related information professionals";
    codes[104]="244 ^ Social science and related professionals";
    codes[105]="2441 ^ Economists";
    codes[106]="2442 ^ Sociologists. anthropologists and related professionals";
    codes[107]="2443 ^ Philosophers, historians and political scientists";
    codes[108]="2444 ^ Philologists translators and interpreters";
    codes[109]="2445 ^ Psychologists";
    codes[110]="2446 ^ Social work professionals";
    codes[111]="245 ^ Writers and creative or performing artists";
    codes[112]="2451 ^ Authors, journalists and other writers";
    codes[113]="2452 ^ Sculptors. painters and related artists";
    codes[114]="2453 ^ Composers. musicians and singers";
    codes[115]="2454 ^ Choreographers and dancers";
    codes[116]="2455 ^ Film, stage and related actors and directors";
    codes[117]="246 ^ Religious professionals";
    codes[118]="2460 ^ Religious professionals";
    codes[119]="31 ^ Computing, engineering and science associate professionals";
    codes[120]="311 ^ Physical and engineering science technicians";
    codes[121]="3111 ^ Chemical and physical science technicians";
    codes[122]="3112 ^ Civil engineering technicians";
    codes[123]="3113 ^ Electrical engineering technicians";
    codes[124]="3114 ^ Electronics and telecommunications engineering technicians";
    codes[125]="3115 ^ Mechanical engineering technicians";
    codes[126]="3116 ^ Chemical engineering technicians";
    codes[127]="3117 ^ Mining and metallurgical technicians";
    codes[128]="3118 ^ Draughts persons";
    codes[129]="3119 ^ Physical and engineering science technicians not elsewhere classified";
    codes[130]="312 ^ Computer associate professionals";
    codes[131]="3121 ^ Computer assistants";
    codes[132]="3122 ^ Computer equipment operators";
    codes[133]="3123 ^ Industrial robot controllers.";
    codes[134]="313 ^ Optical and electronic equipment operators";
    codes[135]="3131 ^ Photographers and image and sound recording equipment operators";
    codes[136]="3132 ^ Broadcasting and telecommunications equipment operators";
    codes[137]="3133 ^ Medical equipment operators";
    codes[138]="3139 ^ Optical and electronic equipment operators not elsewhere classified";
    codes[139]="314 ^ Ship and aircraft controllers and technicians";
    codes[140]="3141 ^ Ships' engineers";
    codes[141]="3142 ^ Ships deck officers and pilots";
    codes[142]="3143 ^ Aircraft pilots and related associate professionals";
    codes[143]="3144 ^ Air traffic controllers";
    codes[144]="3145 ^ Air traffic safety technicians";
    codes[145]="315 ^ Safety and quality inspectors";
    codes[146]="3151 ^ Building and fire inspectors";
    codes[147]="3152 ^ Quality control";
    codes[148]="32 ^ Healthcare and life science associate professionals";
    codes[149]="321 ^ Life science technicians and related associate professionals";
    codes[150]="3211 ^ Life science technicians";
    codes[151]="3212 ^ Agronomy and forestry technicians";
    codes[152]="3213 ^ Farming and forestry advisers";
    codes[153]="322 ^ Modern health associate professionals (except nursing)";
    codes[154]="3221 ^ Medical assistants";
    codes[155]="3222 ^ Sanitarians";
    codes[156]="3223 ^ Dieticians and nutritionists";
    codes[157]="3224 ^ Optometrists and opticians";
    codes[158]="3225 ^ Dental assistants";
    codes[159]="3226 ^ Physiotherapists and related associate professionals";
    codes[160]="3227 ^ Veterinary assistants";
    codes[161]="3228 ^ Pharmaceutical assistants";
    codes[162]="3229 ^ Modern health associate professionals (except nursing) not elsewhere classified";
    codes[163]="323 ^ Nursing and midwifery associate professionals";
    codes[164]="3231 ^ Nursing associate professionals";
    codes[165]="3232 ^ Midwifery associate professionals";
    codes[166]="324 ^ Traditional medicine practitioners and faith healers";
    codes[167]="3241 ^ Traditional medicine practitioners";
    codes[168]="3242 ^ Faith healers";
    codes[169]="33 ^ Teaching associate professionals";
    codes[170]="331 ^ Primary education teaching associate professionals";
    codes[171]="3310 ^ Primary education teaching associate professionals";
    codes[172]="332 ^ Pre-primary education teaching associate professionals";
    codes[173]="3320 ^ Pre-primary education teaching associate professionals";
    codes[174]="333 ^ Special education teaching associate professionals";
    codes[175]="3330 ^ Special education teaching associate professionals";
    codes[176]="334 ^ Other teaching associate professionals";
    codes[177]="3340 ^ Other teaching associate professionals";
    codes[178]="34 ^ Finance, sales and administrative associate professionals";
    codes[179]="341 ^ Finance and sales associate professionals";
    codes[180]="3411 ^ Securities and finance dealers and brokers";
    codes[181]="3412 ^ Insurance representatives";
    codes[182]="3413 ^ Estate agents";
    codes[183]="3414 ^ Travel consultants and organisers";
    codes[184]="3415 ^ Technical and commercial sales representatives";
    codes[185]="3416 ^ Buyers";
    codes[186]="3417 ^ Appraisers valuers and auctioneers";
    codes[187]="3419 ^ Finance and sales associate professionals not elsewhere classified";
    codes[188]="342 ^ Business services agents and trade brokers";
    codes[189]="3421 ^ Trade brokers";
    codes[190]="3422 ^ Clearing and forwarding agents";
    codes[191]="3423 ^ Employment agents and labour contractors";
    codes[192]="3429 ^ Business services agents and trade broke not elsewhere classified";
    codes[193]="343 ^ Administrative associate professionals";
    codes[194]="3431 ^ Administrative secretaries and related associate professionals";
    codes[195]="3432 ^ Legal and related business associate professionals";
    codes[196]="3433 ^ Bookkeepers";
    codes[197]="3434 ^ Statistical. mathematical and related associate professionals";
    codes[198]="3439 ^ Administrative associate professionals not elsewhere classified";
    codes[199]="344 ^ Customs, tax and related government associate professionals";
    codes[200]="3441 ^ Customs and border inspectors";
    codes[201]="3442 ^ Government tax and excise officials";
    codes[202]="3443 ^ Government social benefits officials";
    codes[203]="3444 ^ Government licensing officials";
    codes[204]="3449 ^ Customs, tax and related government associate professionals not elsewhere classified";
    codes[205]="345 ^ Police inspectors and detective";
    codes[206]="3450 ^ Police inspectors and detectives";
    codes[207]="346 ^ Social work associate professionals";
    codes[208]="3460 ^ Social work associate professionals";
    codes[209]="347 ^ Artistic, entertainment and sport associate professionals";
    codes[210]="3471 ^ Decorators and commercial designers";
    codes[211]="3472 ^ Radio, television and other announcers";
    codes[212]="3473 ^ Street. night-club and related musicians, singers and dancers";
    codes[213]="3474 ^ Clowns. magicians, acrobats and related associate professionals";
    codes[214]="3475 ^ Athletes. sports persons and related associate professionals";
    codes[215]="348 ^ Religious associate professionals";
    codes[216]="3480 ^ Religious associate professionals";
    codes[217]="41 ^ Office staff";
    codes[218]="411 ^ Secretaries and keyboard-operating clerks";
    codes[219]="4111 ^ Stenographers and typists";
    codes[220]="4112 ^ Word-processor and related operators";
    codes[221]="4113 ^ Data entry operators";
    codes[222]="4114 ^ Calculating-machine operators";
    codes[223]="4115 ^ Secretaries";
    codes[224]="412 ^ Numerical clerks";
    codes[225]="4121 ^ Accounting and bookkeeping clerks";
    codes[226]="4122 ^ Statistical and finance clerks";
    codes[227]="413 ^ Material-recording and transport clerks";
    codes[228]="4131 ^ Stock clerks";
    codes[229]="4132 ^ Production clerks";
    codes[230]="4133 ^ Transport clerks";
    codes[231]="414 ^ Library, mail and related clerks";
    codes[232]="4141 ^ Library and filing clerks";
    codes[233]="4142 ^ Mail carriers and sorting clerks";
    codes[234]="4143 ^ Coding, proof-reading and related clerks";
    codes[235]="4144 ^ Scribes and related workers";
    codes[236]="419 ^ Other office clerks";
    codes[237]="4190 ^ Other office clerks";
    codes[238]="42 ^ Customer service staff";
    codes[239]="421 ^ Cashiers, tellers and related clerks";
    codes[240]="4211 ^ Cashiers and ticket clerks";
    codes[241]="4212 ^ Tellers and other counter clerks";
    codes[242]="4213 ^ Bookmakers and croupiers";
    codes[243]="4214 ^ Pawnbrokers and money-lenders";
    codes[244]="4215 ^ Debt-collectors and related workers";
    codes[245]="422 ^ Client information clerks";
    codes[246]="4221 ^ Travel agency and related clerks";
    codes[247]="4222 ^ Receptionists and information clerks";
    codes[248]="4223 ^ Telephone switchboard operators";
    codes[249]="51 ^ Hotel, catering and personal services staff";
    codes[250]="511 ^ Travel attendants and related workers";
    codes[251]="5111 ^ Travel attendants and travel stewards";
    codes[252]="5112 ^ Transport conductors";
    codes[253]="5113 ^ Travel guides";
    codes[254]="512 ^ Housekeeping and restaurant services workers";
    codes[255]="5121 ^ Housekeepers and related workers";
    codes[256]="5122 ^ Cooks";
    codes[257]="5123 ^ Waiters, waitresses and bartenders";
    codes[258]="513 ^ Personal care and related workers";
    codes[259]="5131 ^ Child-care workers";
    codes[260]="5132 ^ Institution-based personal care workers";
    codes[261]="5133 ^ Home-based personal care workers";
    codes[262]="5139 ^ Personal care and related workers not elsewhere classified";
    codes[263]="514 ^ Other personal services workers";
    codes[264]="5141 ^ Hairdressers barbers, beauticians and related workers";
    codes[265]="5142 ^ Companions and valets";
    codes[266]="5143 ^ Undertakers and embalmers";
    codes[267]="5149 ^ Other personal services workers not elsewhere classified";
    codes[268]="515 ^ Astrologers, fortune-tellers and related workers";
    codes[269]="5151 ^ Astrologers and related workers";
    codes[270]="5152 ^ Fortune-tellers palmists and related workers";
    codes[271]="516 ^ Protective services workers";
    codes[272]="5161 ^ Fire-fighters";
    codes[273]="5162 ^ Police officers";
    codes[274]="5163 ^ Prison guards";
    codes[275]="5169 ^ Protective services workers not elsewhere classified";
    codes[276]="52 ^ Sales staff and fashion work";
    codes[277]="521 ^ Fashion and other models";
    codes[278]="5210 ^ Fashion and other models";
    codes[279]="522 ^ Shop sales persons and demonstrators";
    codes[280]="5220 ^ Shop sales persons and demonstrators";
    codes[281]="523 ^ Stall and market sales persons";
    codes[282]="5230 ^ Stall and market sales persons";
    codes[283]="61 ^ Skilled agricultural, fishery and forestry workers";
    codes[284]="611 ^ Market gardeners and crop growers";
    codes[285]="6111 ^ Field crop and vegetable growers";
    codes[286]="6112 ^ Tree and shrub crop growers";
    codes[287]="6113 ^ Gardeners horticultural and nursery growers";
    codes[288]="6114 ^ Mixed-crop growers";
    codes[289]="612 ^ Market-oriented animal producers and related workers";
    codes[290]="6121 ^ Dairy and livestock producers";
    codes[291]="6122 ^ Poultry producers";
    codes[292]="6123 ^ Apiarists and sericulturists";
    codes[293]="6124 ^ Mixed-animal producers";
    codes[294]="6129 ^ Market-oriented animal producers and related workers not elsewhere classified";
    codes[295]="613 ^ Market-oriented crop and animal producers";
    codes[296]="6130 ^ Market-oriented crop and animal producers";
    codes[297]="614 ^ Forestry and related workers";
    codes[298]="6141 ^ Forestry workers and loggers";
    codes[299]="6142 ^ Charcoal burners and related workers";
    codes[300]="615 ^ Fishery workers, hunters and trappers";
    codes[301]="6151 ^ Aquatic-life cultivation workers";
    codes[302]="6152 ^ Inland and coastal waters fishery workers";
    codes[303]="6153 ^ Deep-sea fishery workers";
    codes[304]="6154 ^ Hunters and trappers";
    codes[305]="62 ^ Subsistence agricultural and fishery workers";
    codes[306]="621 ^ Subsistence agricultural and fishery workers";
    codes[307]="6210 ^ Subsistence agricultural and fishery workers";
    codes[308]="71 ^ Construction, mining and quarrying workers";
    codes[309]="711 ^ Miners, shotfirers, stone cutters and carvers";
    codes[310]="7111 ^ Miners and quarry workers";
    codes[311]="7112 ^ Shotfirers and blasters";
    codes[312]="7113 ^ Stone splitters. cutters and carvers";
    codes[313]="712 ^ Building frame and related trades workers";
    codes[314]="7121 ^ Builders. traditional materials";
    codes[315]="7122 ^ Bricklayers and stonemasons";
    codes[316]="7123 ^ Concrete placers. concrete finishers and related workers";
    codes[317]="7124 ^ Carpenters and joiners";
    codes[318]="7129 ^ Building frame and related trades workers not elsewhere classified";
    codes[319]="713 ^ Building finishers and related trades workers";
    codes[320]="7131 ^ Roofers";
    codes[321]="7132 ^ Floor layers and tile setters";
    codes[322]="7133 ^ Plasterers";
    codes[323]="7134 ^ Insulation workers";
    codes[324]="7135 ^ Glaziers";
    codes[325]="7136 ^ Plumbers and pipe fitters";
    codes[326]="7137 ^ Building and related electricians";
    codes[327]="714 ^ Painters, building structure cleaners and related trades workers";
    codes[328]="7141 ^ Painters and related workers";
    codes[329]="7142 ^ Varnishers and related painters";
    codes[330]="7143 ^ Building structure cleaners";
    codes[331]="72 ^ Metal, machinery and electronic equipment workers";
    codes[332]="721 ^ Metal moulders, welders, sheet-metal workers, structural-metal preparers, and related trades 'worker...";
    codes[333]="7211 ^ Metal moulders and coremakers";
    codes[334]="7212 ^ Welders and flamecutters";
    codes[335]="7213 ^ Sheet-metal workers";
    codes[336]="7214 ^ Structural-metal preparers and erectors";
    codes[337]="7215 ^ Riggers and cable splicers";
    codes[338]="7216 ^ Underwater workers";
    codes[339]="722 ^ Blacksmiths, tool-makers and related trades workers";
    codes[340]="7221 ^ Blacksmiths. hammer-smiths and forging-press workers";
    codes[341]="7222 ^ Tool-makers and related workers";
    codes[342]="7223 ^ Machine-tool setters and setter-operators";
    codes[343]="7224 ^ Metal wheel-grinders, polishers and tool sharpeners";
    codes[344]="723 ^ Machinery mechanics and fitters";
    codes[345]="7231 ^ Motor vehicle mechanics and fitters";
    codes[346]="7232 ^ Aircraft engine mechanics and fitters";
    codes[347]="7233 ^ Agricultural- or industrial-machinery mechanics and fitters";
    codes[348]="724 ^ Electrical and electronic equipment mechanics and fitters";
    codes[349]="7241 ^ Electrical mechanics and fitters";
    codes[350]="7242 ^ Electronics fitters";
    codes[351]="7243 ^ Electronics mechanics and servicers";
    codes[352]="7244 ^ Telegraph and telephone installers and servicers";
    codes[353]="7245 ^ Electrical line installers, repairers and cable jointers";
    codes[354]="73 ^ Precision, handicraft, printing and related trades workers";
    codes[355]="731 ^ Precision workers in metal and related materials";
    codes[356]="7311 ^ Precision-instrument makers and repairers";
    codes[357]="7312 ^ Musical-instrument makers and tuners";
    codes[358]="7313 ^ Jewellery and precious-metal workers";
    codes[359]="732 ^ Potters, glass-makers and related trades workers";
    codes[360]="7321 ^ Abrasive wheel formers. potters and related workers";
    codes[361]="7322 ^ Glass-makers. cutters. grinders and finishers";
    codes[362]="7323 ^ Glass engravers and etchers";
    codes[363]="7324 ^ Glass. ceramics and related decorative painters";
    codes[364]="733 ^ Handicraftworkers in wood, textile, leather and related materials";
    codes[365]="7331 ^ Handicraftworkers in wood and related materials";
    codes[366]="7332 ^ Handicraft workers in textile, leather and related materials";
    codes[367]="734 ^ Printing and related trades workers";
    codes[368]="7341 ^ Compositors. typesetters and related workers";
    codes[369]="7342 ^ Stereotypers and electrotypers";
    codes[370]="7343 ^ Printing engravers and etchers";
    codes[371]="7344 ^ Photographic and related workers";
    codes[372]="7345 ^ Bookbinders and related workers";
    codes[373]="7346 ^ Silk-screen. block and textile printers";
    codes[374]="74 ^ Other craft and related trades workers";
    codes[375]="741 ^ Food processing and related trades workers";
    codes[376]="7411 ^ Butchers, fishmongers and related food preparers";
    codes[377]="7412 ^ Bakers. pastry-cooks and confectionery makers";
    codes[378]="7413 ^ Dairy-products makers";
    codes[379]="7414 ^ Fruit, vegetable and related preservers";
    codes[380]="7415 ^ Food and beverage tasters and graders";
    codes[381]="7416 ^ Tobacco preparers and tobacco products makers";
    codes[382]="742 ^ Wood treaters, cabinet-makers and related trades workers";
    codes[383]="7421 ^ Woodtreaters";
    codes[384]="7422 ^ Cabinet-makers and related workers";
    codes[385]="7423 ^ Woodworking-machine setters and setter-operators";
    codes[386]="7424 ^ Basketry weavers, brush makers and related workers";
    codes[387]="743 ^ Textile, garment and related trades workers";
    codes[388]="7431 ^ Fibre preparers";
    codes[389]="7432 ^ Weavers, knitters and related workers";
    codes[390]="7433 ^ Tailors, dressmakers and hatters";
    codes[391]="7434 ^ Furriers and related workers";
    codes[392]="7435 ^ Textile, leather and related pattern-makers and cutters";
    codes[393]="7436 ^ Sewers, embroiderers and related workers";
    codes[394]="7437 ^ Upholsterers and related workers";
    codes[395]="744 ^ Pelt, leather and shoemaking trades workers";
    codes[396]="7441 ^ Pelt dressers, tanners and fell mongers";
    codes[397]="7442 ^ Shoe-makers and related workers";
    codes[398]="81 ^ Stationary-plant and related operators";
    codes[399]="811 ^ Mining- and mineral-processing-plant operators";
    codes[400]="8111 ^ Mining-plant operators";
    codes[401]="8112 ^ Mineral-ore- and stone-processing-plant operators";
    codes[402]="8113 ^ Well drillers and borers and related workers";
    codes[403]="812 ^ Metal-processing-plant operators";
    codes[404]="8121 ^ Ore and metal furnace operators";
    codes[405]="8122 ^ Metal melters, casters and rolling-mill operators";
    codes[406]="8123 ^ Metal-heat-treating-plant operators";
    codes[407]="8124 ^ Metal drawers and extruders";
    codes[408]="813 ^ Glass, ceramics and related plant operators";
    codes[409]="8131 ^ Glass and ceramics kiln and related machine operators";
    codes[410]="8139 ^ Glass. ceramics and related plant operators not elsewhere classified";
    codes[411]="814 ^ Wood-processing- and papermaking-plant operators";
    codes[412]="8141 ^ Wood-processing-plant operators";
    codes[413]="8142 ^ Paper-pulp plant operators";
    codes[414]="8143 ^ Papermaking-plant operators";
    codes[415]="815 ^ Chemical-processing-plant operators";
    codes[416]="8151 ^ Crushing-. grinding- and chemical-mixing machinery operators";
    codes[417]="8152 ^ Chemical-heat-treating-plant operators";
    codes[418]="8153 ^ Chemical-filtering- and separating-equipment operators";
    codes[419]="8154 ^ Chemical-still and reactor operators (except petroleum and natural gas)";
    codes[420]="8155 ^ Petroleum- and natural-gas-refining-plant operators";
    codes[421]="8159 ^ Chemical-processing-plant operators n elsewhere classified";
    codes[422]="816 ^ Power-production and related plant operators";
    codes[423]="8161 ^ Power-production plant operators";
    codes[424]="8162 ^ Steam-engine and boiler operators";
    codes[425]="8163 ^ Incinerator, water-treatment and related plant operators";
    codes[426]="817 ^ Automated-assembly-line and industrial-robot operators";
    codes[427]="8171 ^ Automated-assembly-line operators";
    codes[428]="8172 ^ Industrial-robot operators";
    codes[429]="82 ^ Machine operators and assemblers";
    codes[430]="821 ^ Metal- and mineral-products machine operators";
    codes[431]="8211 ^ Machine-tool operators";
    codes[432]="8212 ^ Cement and other mineral products machine operators";
    codes[433]="822 ^ Chemical-products machine operators";
    codes[434]="8221 ^ Pharmaceutical- and toiletry-products machine operators";
    codes[435]="8222 ^ Ammunition- and explosive-products machine operators";
    codes[436]="8223 ^ Metal finishing-, plating- and coating-machine operators";
    codes[437]="8224 ^ Photographic-products machine operators";
    codes[438]="8229 ^ Chemical-products machine operators not elsewhere classified";
    codes[439]="823 ^ Rubber- and plastic-products machine operators";
    codes[440]="8231 ^ Rubber-products machine operators";
    codes[441]="8232 ^ Plastic-products machine operators";
    codes[442]="824 ^ Wood-products machine operators";
    codes[443]="8240 ^ Wood-products machine operators";
    codes[444]="825 ^ Printing-, binding- and paper-products machine operators";
    codes[445]="8251 ^ Printing-machine operators";
    codes[446]="8252 ^ Bookbinding-machine operators";
    codes[447]="8253 ^ Paper-products machine operators";
    codes[448]="826 ^ Textile-, fur- and leather-products machine operators";
    codes[449]="8261 ^ Fibre-preparing-, spinning- and winding-machine operators";
    codes[450]="8262 ^ Weaving- and knitting-machine operators";
    codes[451]="8263 ^ Sewing-machine operators";
    codes[452]="8264 ^ Bleaching-, dyeing- and cleaning-machine operators";
    codes[453]="8265 ^ Fur- and leather-preparing-machine operators";
    codes[454]="8266 ^ Shoemaking- and related machine operators";
    codes[455]="8269 ^ Textile-, fur- and leather-products machine operators not elsewhere classified";
    codes[456]="827 ^ Food and related products machine operators";
    codes[457]="8271 ^ Meat- and fish-processing-machine operators";
    codes[458]="8272 ^ Dairy-products machine operators";
    codes[459]="8273 ^ Grain- and spice-milling-machine operators";
    codes[460]="8274 ^ Baked-goods, cereal and chocolate-products machine operators";
    codes[461]="8275 ^ Fruit-, vegetable- and nut-processing-machine operators";
    codes[462]="8276 ^ Sugar production machine operators";
    codes[463]="8277 ^ Tea-, coffee-, and cocoa-processing-machine operators";
    codes[464]="8278 ^ Brewers-, wine and other beverage machine operators";
    codes[465]="8279 ^ Tobacco production machine operators";
    codes[466]="828 ^ Assemblers";
    codes[467]="8281 ^ Mechanical-machinery assemblers";
    codes[468]="8282 ^ Electrical-equipment assemblers";
    codes[469]="8283 ^ Electronic-equipment assemblers";
    codes[470]="8284 ^ Metal-, rubber- and plastic-products assemblers";
    codes[471]="8285 ^ Wood and related products assemblers";
    codes[472]="8286 ^ Paperboard. textile and related products assemblers";
    codes[473]="829 ^ Other machine operators and assemblers";
    codes[474]="8290 ^ Other machine operators and assemblers";
    codes[475]="83 ^ Drivers and mobile-plant operators";
    codes[476]="831 ^ Locomotive-engine drivers and related workers";
    codes[477]="8311 ^ Locomotive-engine drivers";
    codes[478]="8312 ^ Railway brakers. signallers and shunters";
    codes[479]="832 ^ Motor-vehicle drivers";
    codes[480]="8321 ^ Motor-cycle drivers";
    codes[481]="8322 ^ Car, taxi and van drivers";
    codes[482]="8323 ^ Bus and tram drivers";
    codes[483]="8324 ^ Heavy truck and lorry drivers";
    codes[484]="833 ^ Agricultural and other mobile-plant operators";
    codes[485]="8331 ^ Motorised farm and forestry plant operators";
    codes[486]="8332 ^ Earth-moving- and related plant operators";
    codes[487]="8333 ^ Crane. hoist and related plant operators";
    codes[488]="8334 ^ Lifting-truck operators";
    codes[489]="834 ^ Ships' deck crews and related workers";
    codes[490]="8340 ^ Ships' deck crews and related workers";
    codes[491]="91 ^ Sales, services and cleaning elementary occupations";
    codes[492]="911 ^ Street vendors and related workers";
    codes[493]="9111 ^ Street food vendors";
    codes[494]="9112 ^ Street vendors. non-food products";
    codes[495]="9113 ^ Door-to-door and telephone salespersons";
    codes[496]="912 ^ Shoe cleaning and other street services elementary occupations";
    codes[497]="9120 ^ Shoe cleaning and other street services elementary occupations";
    codes[498]="913 ^ Domestic and related helpers, cleaners and launderers";
    codes[499]="9131 ^ Domestic helpers and cleaners";
    codes[500]="9132 ^ Helpers and cleaners in offices. hotels and other establishments";
    codes[501]="9133 ^ Hand-launderers and pressers";
    codes[502]="914 ^ Building caretakers, window and related cleaners";
    codes[503]="9141 ^ Building caretakers";
    codes[504]="9142 ^ Vehicle, window and related cleaners";
    codes[505]="915 ^ Messengers, porters, doorkeepers and related workers";
    codes[506]="9151 ^ Messengers, package and luggage porters and deliverers";
    codes[507]="9152 ^ Doorkeepers. watchpersons and related workers";
    codes[508]="9153 ^ Vending-machine money collectors. meter readers and related workers";
    codes[509]="916 ^ Garbage collectors and related labourers";
    codes[510]="9161 ^ Garbage collectors";
    codes[511]="9162 ^ Sweepers and related labourers";
    codes[512]="92 ^ Agricultural, fishery and related labourers";
    codes[513]="921 ^ Agricultural, fishery and related labourers";
    codes[514]="9211 ^ Farm-hands and labourers";
    codes[515]="9212 ^ Forestry labourers";
    codes[516]="9213 ^ Fishery, hunting and trapping labourers";
    codes[517]="93 ^ Labourers in mining, construction, manufacturing and transport";
    codes[518]="931 ^ Mining and construction labourers";
    codes[519]="9311 ^ Mining and quarrying labourers";
    codes[520]="9312 ^ Construction and maintenance labourers roads, dams and similar constructions";
    codes[521]="9313 ^ Building construction labourers";
    codes[522]="932 ^ Manufacturing labourers";
    codes[523]="9321 ^ Assembling labourers";
    codes[524]="9322 ^ Hand packers and other manufacturing labourers";
    codes[525]="933 ^ Transport labourers and freight handlers";
    codes[526]="9331 ^ Hand or pedal vehicle drivers";
    codes[527]="9332 ^ Drivers of animal-drawn vehicles and machinery";
    codes[528]="9333 ^ Freight handlers";

    codes.map! { |str| str.split(' ^ ')[0] }

    return @isco_codes = codes
  end
  
  def self.country_en_2_code(country)
    unless @countries_en
      countries = {}
      countries["Austria"] = "AT" 
      countries["AS"] = "AS"
      countries["Belgium"] = "BE" 
      countries["Bulgaria"] = "BG" 
      countries["Cyprus"] = "CY" 
      countries["Czech Republic"] = "CZ" 
      countries["Denmark"] = "DK" 
      countries["Estonia"] = "EE" 
      countries["Finland"] = "FI" 
      countries["France"] = "FR" 
      countries["Germany"] = "DE" 
      countries["Greece"] = "GR" 
      countries["Hungary"] = "HU" 
      countries["Iceland"] = "IS" 
      countries["Ireland"] = "IR" 
      countries["Italy"] = "IT" 
      countries["Latvia"] = "LV" 
      countries["Liechtenstein"] = "LI" 
      countries["Lithuania"] = "LT" 
      countries["Luxembourg"] = "LU" 
      countries["Malta"] = "MT" 
      countries["Netherlands"] = "NL" 
      countries["NL"] = "NL" 
      countries["Norway"] = "NO" 
      countries["NO"] = "NO" 
      countries["Poland"] = "PL" 
      countries["Portugal"] = "PT" 
      countries["Romania"] = "RO" 
      countries["Slovakia"] = "SK" 
      countries["Slovenia"] = "SI" 
      countries["Spain"] = "ES" 
      countries["Sweden"] = "SE" 
      countries["Switzerland"] = "CH" 
      countries["United Kingdom"] = "GB" 
      countries["GE"] = "GE"
      @countries_en = countries
    end 
    country_code = @countries_en[country]
    raise country.inspect unless country_code
    return country_code
  end


  def self.locations
    return @locations if @locations

    regions = []
    regions[0]="AT ^ RD11 # Burgenland";
    regions[1]="AT ^ RD21 # Kärnten";
    regions[2]="AT ^ RD12 # Niederösterreich";
    regions[3]="AT ^ RD31 # Oberösterreich";
    regions[4]="AT ^ RD32 # SALZBURG";
    regions[5]="AT ^ RD22 # Steiermark";
    regions[6]="AT ^ RD33 # Tirol";
    regions[7]="AT ^ RD34 # Vorarlberg";
    regions[8]="AT ^ RD13 # Wien";
    regions[9]="BE ^ R53 # REGION BRUXELLES-CAPITALE / BRUSSELS HOOFDSTEDELIJK GEWEST";
    regions[10]="BE ^ R52 # REGION WALLONNE";
    regions[11]="BE ^ R51 # VLAAMS GEWEST";
    regions[12]="BG ^ BG32 # SEVEREN TSENTRALEN";
    regions[13]="BG ^ BG33 # SEVEROIZTOCHEN";
    regions[14]="BG ^ BG31 # SEVEROZAPADEN";
    regions[15]="BG ^ BG34 # YUGOIZTOCHEN";
    regions[16]="BG ^ BG41 # YUGOZAPADEN";
    regions[17]="BG ^ BG42 # YUZHEN TSENTRALEN";
    regions[18]="CH ^ RV02 # Espace Mittelland";
    regions[19]="CH ^ RV03 # Nordwestschweiz";
    regions[20]="CH ^ RV05 # Ostschweiz";
    regions[21]="CH ^ RV01 # Région lémanique";
    regions[22]="CH ^ RV07 # Ticino";
    regions[23]="CH ^ RV06 # Zentralschweiz";
    regions[24]="CH ^ RV04 # Zürich";
    regions[25]="CZ ^ RL031 # Jihocesky";
    regions[26]="CZ ^ RL062 # Jihomoravsky";
    regions[27]="CZ ^ RL041 # Karlovarsky";
    regions[28]="CZ ^ RL052 # Kralovehradecky";
    regions[29]="CZ ^ RL051 # Liberecky";
    regions[30]="CZ ^ RL080 # Moravskoslezsky";
    regions[31]="CZ ^ RL071 # Olomoucky";
    regions[32]="CZ ^ RL053 # Pardubicky";
    regions[33]="CZ ^ RL032 # Plzensky";
    regions[34]="CZ ^ RL01 # Praha";
    regions[35]="CZ ^ RL020 # Stredocesky";
    regions[36]="CZ ^ RL042 # Ustecky";
    regions[37]="CZ ^ RL061 # Vysocina";
    regions[38]="CZ ^ RL072 # Zlinsky";
    regions[39]="DE ^ R18 # BADEN-WUERTTEMBERG";
    regions[40]="DE ^ R19 # BAYERN";
    regions[41]="DE ^ R1B # BERLIN";
    regions[42]="DE ^ R1C # BRANDENBURG";
    regions[43]="DE ^ R14 # BREMEN";
    regions[44]="DE ^ R12 # HAMBURG";
    regions[45]="DE ^ R16 # HESSEN";
    regions[46]="DE ^ R1D # MECKLENBURG-VORPOMMERN";
    regions[47]="DE ^ R13 # NIEDERSACHSEN";
    regions[48]="DE ^ R15 # NORDRHEIN-WESTFALEN";
    regions[49]="DE ^ R17 # RHEINLAND-PFALZ";
    regions[50]="DE ^ R1A # SAARLAND";
    regions[51]="DE ^ R1E # SACHSEN";
    regions[52]="DE ^ R1F # SACHSEN-ANHALT";
    regions[53]="DE ^ R11 # SCHLESWIG-HOLSTEIN";
    regions[54]="DE ^ R1G # THUERINGEN";
    regions[55]="DK ^ DK01 # HOVEDSTADEN";
    regions[56]="DK ^ DK04 # MIDTJYLLAND";
    regions[57]="DK ^ DK05 # NORDJYLLAND";
    regions[58]="DK ^ DK02 # SJAELLAND";
    regions[59]="DK ^ DK03 # SYDDANMARK";
    regions[60]="ES ^ RB61 # ANDALUCIA";
    regions[61]="ES ^ RB24 # ARAGON";
    regions[62]="ES ^ RB12 # ASTURIAS";
    regions[63]="ES ^ RB53 # BALEARES";
    regions[64]="ES ^ RB7 # CANARIAS";
    regions[65]="ES ^ RB13 # CANTABRIA";
    regions[66]="ES ^ RB42 # CASTILLA-LA MANCHA";
    regions[67]="ES ^ RB41 # CASTILLA-LEON";
    regions[68]="ES ^ RB51 # CATALUNA";
    regions[69]="ES ^ RB63 # CEUTA Y MELILLA";
    regions[70]="ES ^ RB52 # COMUNIDAD VALENCIANA";
    regions[71]="ES ^ RB43 # EXTREMADURA";
    regions[72]="ES ^ RB11 # GALICIA";
    regions[73]="ES ^ RB3 # MADRID";
    regions[74]="ES ^ RB62 # MURCIA";
    regions[75]="ES ^ RB22 # NAVARRA";
    regions[76]="ES ^ RB21 # PAIS VASCO";
    regions[77]="ES ^ RB23 # RIOJA";
    regions[78]="FI ^ RF211 # Ahvenanmaa/Åland";
    regions[79]="FI ^ RF127 # Etelä-Karjala";
    regions[80]="FI ^ RF142 # Etelä-Pohjanmaa";
    regions[81]="FI ^ RF131 # Etelä-Savo";
    regions[82]="FI ^ RF112 # Itä-Uusimaa";
    regions[83]="FI ^ RF134 # Kainuu";
    regions[84]="FI ^ RF123 # Kanta-Häme";
    regions[85]="FI ^ RF144 # Keski-Pohjanmaa";
    regions[86]="FI ^ RF141 # Keski-Suomi";
    regions[87]="FI ^ RF126 # Kymenlaakso";
    regions[88]="FI ^ RF152 # Lappi";
    regions[89]="FI ^ RF124 # Pirkanmaa";
    regions[90]="FI ^ RF143 # Pohjanmaa";
    regions[91]="FI ^ RF133 # Pohjois-Karjala";
    regions[92]="FI ^ RF151 # Pohjois-Pohjanmaa";
    regions[93]="FI ^ RF132 # Pohjois-Savo";
    regions[94]="FI ^ RF125 # Päijät-Häme";
    regions[95]="FI ^ RF122 # Satakunta";
    regions[96]="FI ^ RF111 # Uusimaa";
    regions[97]="FI ^ RF121 # Varsinais-Suomi";
    regions[98]="FR ^ R242 # ALSACE";
    regions[99]="FR ^ R261 # AQUITAINE";
    regions[100]="FR ^ R272 # AUVERGNE";
    regions[101]="FR ^ R225 # BASSE-NORMANDIE";
    regions[102]="FR ^ R226 # BOURGOGNE";
    regions[103]="FR ^ R252 # BRETAGNE";
    regions[104]="FR ^ R224 # CENTRE";
    regions[105]="FR ^ R221 # CHAMPAGNE-ARDENNE";
    regions[106]="FR ^ R283 # CORSE";
    regions[107]="FR ^ R29 # DEPARTEMENTS D'OUTRE-MER";
    regions[108]="FR ^ R243 # FRANCHE-COMTE";
    regions[109]="FR ^ R223 # HAUTE-NORMANDIE";
    regions[110]="FR ^ R21 # ILE DE FRANCE";
    regions[111]="FR ^ R281 # LANGUEDOC-ROUSSILLON";
    regions[112]="FR ^ R263 # LIMOUSIN";
    regions[113]="FR ^ R241 # LORRAINE";
    regions[114]="FR ^ R262 # MIDI-PYRENEES";
    regions[115]="FR ^ R23 # NORD-PAS-DE-CALAIS";
    regions[116]="FR ^ R251 # PAYS DE LA LOIRE";
    regions[117]="FR ^ R222 # PICARDIE";
    regions[118]="FR ^ R253 # POITOU-CHARENTES";
    regions[119]="FR ^ R282 # PROVENCE-ALPES-COTE D'AZUR";
    regions[120]="FR ^ R271 # RHONE-ALPES";
    regions[121]="GR ^ RA11 # ANATOLIKI MAKEDONIA, THRAKI";
    regions[122]="GR ^ RA003 # ATTIKI";
    regions[123]="GR ^ RA23 # DYTIKI ELLADA";
    regions[124]="GR ^ RA13 # DYTIKI MAKEDONIA";
    regions[125]="GR ^ RA22 # IONIA NISIA";
    regions[126]="GR ^ RA21 # IPEIROS";
    regions[127]="GR ^ RA12 # KENTRIKI MAKEDONIA";
    regions[128]="GR ^ RA43 # KRITI";
    regions[129]="GR ^ RA42 # NOTIO AIGAIO";
    regions[130]="GR ^ RA25 # PELOPONNISOS";
    regions[131]="GR ^ RA24 # STEREA ELLADA";
    regions[132]="GR ^ RA14 # THESSALIA";
    regions[133]="GR ^ RA41 # VOREIO AIGAIO";
    regions[134]="HU ^ RN07 # Del-Alfold";
    regions[135]="HU ^ RN04 # Del-Dunantul";
    regions[136]="HU ^ RN06 # Eszak-Alfold";
    regions[137]="HU ^ RN05 # Eszak-Magyarorszag";
    regions[138]="HU ^ RN02 # Kozep-Dunantul";
    regions[139]="HU ^ RN01 # Kozep-Magyarorszag";
    regions[140]="HU ^ RN03 # Nyugat-Dunantul";
    regions[141]="IR ^ R8006 # DONEGAL";
    regions[142]="IR ^ R8001 # EAST";
    regions[143]="IR ^ R8005 # MID WEST";
    regions[144]="IR ^ R8007 # MIDLANDS";
    regions[145]="IR ^ R8003 # SOUTH EAST (IRL)";
    regions[146]="IR ^ R8002 # SOUTH WEST (IRL)";
    regions[147]="IR ^ R8008 # WEST";
    regions[148]="IS ^ RH # ISLAND";
    regions[149]="IT ^ R381 # ABRUZZI";
    regions[150]="IT ^ R392 # BASILICATA";
    regions[151]="IT ^ R393 # CALABRIA";
    regions[152]="IT ^ R37 # CAMPANIA";
    regions[153]="IT ^ R34 # EMILIA-ROMAGNA";
    regions[154]="IT ^ R333 # FRIULI-VENEZIA GIULIA";
    regions[155]="IT ^ R36 # LAZIO";
    regions[156]="IT ^ R313 # LIGURIA";
    regions[157]="IT ^ R32 # LOMBARDIA";
    regions[158]="IT ^ R353 # MARCHE";
    regions[159]="IT ^ R382 # MOLISE";
    regions[160]="IT ^ R311 # PIEMONTE";
    regions[161]="IT ^ R391 # PUGLIA";
    regions[162]="IT ^ R3B # SARDEGNA";
    regions[163]="IT ^ R3A # SICILIA";
    regions[164]="IT ^ R351 # TOSCANA";
    regions[165]="IT ^ R331 # TRENTINO-ALTO ADIGE/SÜDTIROL";
    regions[166]="IT ^ R352 # UMBRIA";
    regions[167]="IT ^ R312 # VALLE D'AOSTA";
    regions[168]="IT ^ R332 # VENETO";
    regions[169]="LI ^ RJ # LIECHTENSTEIN";
    regions[170]="LT ^ LT001 # ALYTAUS APSKRITIS";
    regions[171]="LT ^ LT002 # KAUNO APSKRITIS";
    regions[172]="LT ^ LT003 # KLAIPEDOS APSKRITIS";
    regions[173]="LT ^ LT004 # MARIJAMPOLES APSKRITIS";
    regions[174]="LT ^ LT005 # PANEVEZIO APSKRITIS";
    regions[175]="LT ^ LT006 # SIAULIU APSKRITIS";
    regions[176]="LT ^ LT007 # TAURAGES APSKRITIS";
    regions[177]="LT ^ LT008 # TELSIU APSKRITIS";
    regions[178]="LT ^ LT009 # UTENOS APSKRITIS";
    regions[179]="LT ^ LT00A # VILNIAUS APSKRITIS";
    regions[180]="LU ^ R6 # LUXEMBOURG (GRAND-DUCHE)";
    regions[181]="NL ^ R413 # DRENTHE";
    regions[182]="NL ^ R425 # FLEVOLAND";
    regions[183]="NL ^ R412 # FRIESLAND";
    regions[184]="NL ^ R424 # GELDERLAND";
    regions[185]="NL ^ R411 # GRONINGEN";
    regions[186]="NL ^ R452 # LIMBURG (NL)";
    regions[187]="NL ^ R451 # NOORD-BRABANT";
    regions[188]="NL ^ R472 # NOORD-HOLLAND";
    regions[189]="NL ^ R423 # OVERIJSSEL";
    regions[190]="NL ^ R471 # UTRECHT";
    regions[191]="NL ^ R474 # ZEELAND";
    regions[192]="NL ^ R473 # ZUID-HOLLAND";
    regions[193]="NO ^ RG2 # Agder/Rogaland -";
    regions[194]="NO ^ RG02 # Akershus -";
    regions[195]="NO ^ RG04 # Hedmark";
    regions[196]="NO ^ RG5 # Nord-Norge";
    regions[197]="NO ^ RG1 # Oestlandet";
    regions[198]="NO ^ RG4 # Troendelag-";
    regions[199]="NO ^ RG3 # Vestlandet -";
    regions[200]="PL ^ RQ01 # Dolnoslaskie";
    regions[201]="PL ^ RQ02 # Kujawsko-Pomorskie";
    regions[202]="PL ^ RQ05 # Lodzkie";
    regions[203]="PL ^ RQ03 # Lubelskie";
    regions[204]="PL ^ RQ04 # Lubuskie";
    regions[205]="PL ^ RQ06 # Malopolskie";
    regions[206]="PL ^ RQ07 # Mazowieckie";
    regions[207]="PL ^ RQ08 # Opolskie";
    regions[208]="PL ^ RQ09 # Podkarpackie";
    regions[209]="PL ^ RQ0A # Podlaskie";
    regions[210]="PL ^ RQ0B # Pomorskie";
    regions[211]="PL ^ RQ0C # Slaskie";
    regions[212]="PL ^ RQ0D # Swietokrzyskie";
    regions[213]="PL ^ RQ0E # Warminsko-Mazurskie";
    regions[214]="PL ^ RQ0F # Wielkopolskie";
    regions[215]="PL ^ RQ0G # Zachodniopomorskie";
    regions[216]="PT ^ RC2 # ACORES";
    regions[217]="PT ^ RC14 # ALENTEJO";
    regions[218]="PT ^ RC15 # ALGARVE";
    regions[219]="PT ^ RC12 # CENTRO (P)";
    regions[220]="PT ^ RC13 # LISBOA E VALE DO TEJO";
    regions[221]="PT ^ RC3 # MADEIRA";
    regions[222]="PT ^ RC11 # NORTE";
    regions[223]="RO ^ RO32 # BUCURESTI";
    regions[224]="RO ^ RO12 # CENTRU";
    regions[225]="RO ^ RO21 # NORD-EST";
    regions[226]="RO ^ RO11 # NORD-VEST";
    regions[227]="RO ^ RO31 # SUD";
    regions[228]="RO ^ RO22 # SUD-EST";
    regions[229]="RO ^ RO41 # SUD-VEST";
    regions[230]="RO ^ RO42 # VEST";
    regions[231]="SE ^ RE041 # Blekinge";
    regions[232]="SE ^ RE062 # Dalarna";
    regions[233]="SE ^ RE034 # Gotland";
    regions[234]="SE ^ RE063 # Gävleborg";
    regions[235]="SE ^ RE051 # Halland";
    regions[236]="SE ^ RE072 # Jämtland";
    regions[237]="SE ^ RE031 # Jönköping";
    regions[238]="SE ^ RE033 # Kalmar";
    regions[239]="SE ^ RE032 # Kronoberg";
    regions[240]="SE ^ RE082 # Norrbotten";
    regions[241]="SE ^ RE042 # Skåne";
    regions[242]="SE ^ RE011 # Stockholm";
    regions[243]="SE ^ RE022 # Södermanland";
    regions[244]="SE ^ RE021 # Uppsala";
    regions[245]="SE ^ RE061 # Värmland";
    regions[246]="SE ^ RE081 # Västerbotten";
    regions[247]="SE ^ RE071 # Västernorrland";
    regions[248]="SE ^ RE025 # Västmanland";
    regions[249]="SE ^ RE052 # Västra Götaland";
    regions[250]="SE ^ RE024 # Örebro";
    regions[251]="SE ^ RE023 # Östergötland";
    regions[252]="SI ^ RS009 # Gorenjska";
    regions[253]="SI ^ RS00B # Goriska";
    regions[254]="SI ^ RS00D # Jugovzhodna Slovenija";
    regions[255]="SI ^ RS003 # Koroska";
    regions[256]="SI ^ RS00A # Notranjsko-kraska";
    regions[257]="SI ^ RS00C # Obalno-kraska";
    regions[258]="SI ^ RS00E # Osrednjeslovenska";
    regions[259]="SI ^ RS002 # Podravska";
    regions[260]="SI ^ RS001 # Pomurska";
    regions[261]="SI ^ RS004 # Savinjska";
    regions[262]="SI ^ RS006 # Spodnjeposavska";
    regions[263]="SI ^ RS005 # Zasavska";
    regions[264]="UK ^ R74 # EAST ANGLIA";
    regions[265]="UK ^ R73 # EAST MIDLANDS";
    regions[266]="UK ^ R755 # GREATER LONDON";
    regions[267]="UK ^ R71 # NORTH";
    regions[268]="UK ^ R78 # NORTH WEST (UK)";
    regions[269]="UK ^ R7B # NORTHERN IRELAND";
    regions[270]="UK ^ R7A # SCOTLAND";
    regions[271]="UK ^ R75 # SOUTH EAST (UK)";
    regions[272]="UK ^ R76 # SOUTH WEST (UK)";
    regions[273]="UK ^ R79 # WALES";
    regions[274]="UK ^ R77 # WEST MIDLANDS";
    regions[275]="UK ^ R72 # YORKSHIRE AND HUMBERSIDE";


    @locations = regions.inject({}) { |hash, str| 
      country, region = str.split(' # ')[0].split(' ^ ') 
      hash[country] ||= []
      hash[country] << region
      hash
    }
    return @locations
  end
end
