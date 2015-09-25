class InventoryItem < ActiveRecord::Base
  belongs_to :item
  belongs_to :player

  def self.candidate_key
    [:player_id, :item_id]
  end
end
