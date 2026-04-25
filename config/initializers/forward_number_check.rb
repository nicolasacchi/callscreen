# Validate FORWARD_NUMBER format at boot to prevent malformed Dial TeXML
# from being generated when an inbound call needs to be forwarded.
forward_number = ENV["FORWARD_NUMBER"]
if forward_number.present? && forward_number !~ /\A\+?[0-9]{6,15}\z/
  raise "FORWARD_NUMBER environment variable is invalid (got: #{forward_number.inspect})"
end
