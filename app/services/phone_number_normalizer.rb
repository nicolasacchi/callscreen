class PhoneNumberNormalizer
  def self.normalize(number, default_country: "IT")
    return number if number.blank?

    phone = Phonelib.parse(number, default_country)
    phone.valid? ? phone.e164 : number.strip
  end
end
