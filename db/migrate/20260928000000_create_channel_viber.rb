class CreateChannelViber < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_viber do |t|
      t.bigint :account_id, null: false
      t.string :bot_id, null: false
      t.string :bot_name, null: false
      t.string :bot_uri
      t.text :encrypted_bot_token, null: false
      t.string :webhook_identifier, null: false
      t.string :webhook_status, null: false, default: 'pending'
      t.string :webhook_error
      t.timestamps
    end
    add_index :channel_viber, :account_id
    add_index :channel_viber, :bot_id, unique: true
    add_index :channel_viber, :webhook_identifier, unique: true
  end
end
