class AddActsAsTaggableOn < ActiveRecord::Migration
  tag :predeploy

  def self.up
    create_table :tags do |t|
      t.column :name, :string
    end

    create_table :taggings do |t|
      t.column :tag_id, :integer, :limit => 8
      t.column :taggable_id, :integer, :limit => 8
      t.column :taggable_type, :string
      t.column :tagger_id, :integer, :limit => 8
      t.column :tagger_type, :string

      # You should make sure that the column created is
      # long enough to store the required class names.
      t.column :context, :string

      t.timestamps
    end

    add_index :taggings, :tag_id
    add_index :taggings, [:taggable_id, :taggable_type]#, :context]
  end

  def self.down
    drop_table :taggings
    drop_table :tags
  end

end
