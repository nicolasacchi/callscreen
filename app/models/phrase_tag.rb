class PhraseTag < ApplicationRecord
  belongs_to :phrase
  belongs_to :tag

  validates :phrase_id, uniqueness: { scope: :tag_id }
end
