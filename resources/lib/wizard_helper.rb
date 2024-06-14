class WizardHelper
  # refresh_segments: Updates the names of segments which can have names duplicated to not being duplicated
  def self.refresh_segments(segments)
    segments.each_with_index do |segment, index|
      if segment["name"].start_with?"br" 
        segment["name"] = "br#{index}"
      else 
        segment["name"] = "bpbr#{index}"
      end
      segments[index] = segment
    end
  end
end