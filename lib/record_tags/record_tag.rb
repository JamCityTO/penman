require 'record_tag_exceptions'

class RecordTag < ActiveRecord::Base
  belongs_to :record, polymorphic: true
  validates_uniqueness_of :tag, scope: [:record_type, :record_id]

  before_save :encode_candidate_key
  after_create :decode_candidate_key
  after_find :decode_candidate_key

  def encode_candidate_key
    if self.candidate_key.is_a? Hash
      self.candidate_key = self.candidate_key.to_json
    end
  end

  def decode_candidate_key
    begin
      self.candidate_key = ActiveSupport::JSON.decode(self.candidate_key).symbolize_keys
    rescue JSON::ParserError
      # This will occur if the candidate key isn't encoded as json.
      #   An example of this would be when we are tagging yaml files as touched when messing with lang.
      #   In that case we store the file path in the candidate key column as a regular string.
    end
  end

  @@enabled = false

  def self.disable
    @@enabled = false
  end

  def self.enable
    @@enabled = true
  end

  @@roots       = []
  @@tree        = {}
  @@polymorphic = []

  def self.register(model)
    reflections = model.reflect_on_all_associations(:belongs_to)

    if reflections.find { |r| r.options[:polymorphic] }.present?
      @@polymorphic << model
    else
      @@roots.push(model) unless @@tree.key?(model)
    end

    @@tree[model] = reflections.reject { |r| r.options[:polymorphic] || r.klass == model }.map(&:klass)
    @@tree[model].each { |ch| @@tree[ch] ||= [] }

    @@roots -= @@tree[model]
  end

  def self.seed_order
    seed_order = []

    recurse_on = -> (node) do
      return unless node.ancestors.include?(Taggable)
      @@tree[node].each { |n| recurse_on.call(n) }
      seed_order |= [node]
    end

    @@roots.each { |node| recurse_on.call(node) }
    @@polymorphic.each { |node| recurse_on.call(node) }

    seed_order | @@polymorphic
  end

  def self.tag(record, tag)
    return unless @@enabled
    candidate_key = record.class.try(:candidate_key) || :reference
    candidate_key = [candidate_key] unless candidate_key.is_a? Array
    raise RecordTagExceptions::InvalidCandidateKeyForRecord unless self.record_has_attributes?(record, candidate_key)

    candidate_key_to_store =
      if ['created', 'destroyed'].include? tag
        Hash[candidate_key.map { |k| [k, record.send(k)] }].to_json
      else # updated
        Hash[candidate_key.map { |k| [k, record.send("#{k}_was")] }].to_json
      end

    created_tag = RecordTag.find_by(record: record, tag: 'created')
    updated_tag = RecordTag.find_by(record: record, tag: 'updated')
    destroyed_tag = RecordTag.find_by(record_type: record.class.name, candidate_key: candidate_key_to_store, tag: 'destroyed')

    raise RecordTagExceptions::TooManyTagsForRecord if [created_tag, updated_tag, destroyed_tag].count { |t| t.present? } > 1

    if created_tag.present?
      case tag
      when 'created'
        raise RecordTagExceptions::BadTracking, RecordTag.format_error_message('created', 'created', candidate_key_to_store)
      when 'updated'
        created_tag.update!(tag: tag)
      when 'destroyed'
        created_tag.destroy!
      end
    elsif updated_tag.present?
      case tag
      when 'created'
        raise RecordTagExceptions::BadTracking, RecordTag.format_error_message('updated', 'created', candidate_key_to_store)
      when 'updated'
        updated_tag.update!(tag: tag)
      when 'destroyed'
        if updated_tag.created_this_session
          updated_tag.destroy!
        else
          updated_tag.update!(tag: tag)
        end
      end
    elsif destroyed_tag.present?
      case tag
      when 'created'
        # We make an updated tag in case non-candidate key attributes have changed, since we don't tack those.
        destroyed_tag.update!(tag: 'updated', record_id: record.id)
      when 'updated'
        raise RecordTagExceptions::BadTracking, RecordTag.format_error_message('destroyed', 'updated', candidate_key_to_store)
      when 'destroyed'
        raise RecordTagExceptions::BadTracking, RecordTag.format_error_message('destroyed', 'destroyed', candidate_key_to_store)
      end
    else # new tag
      RecordTag.create!(record: record, tag: tag, candidate_key: candidate_key_to_store, created_this_session: tag == 'created')
    end
  end

  def self.find_tags_for_model(model)
    self.find_tags_for_models(model)
  end

  def self.find_tags_for_models(*models)
    RecordTag.where(record_type: models.map { |m| (m.is_a? String) ? m : m.class_name })
  end

  def self.create_custom(attributes = {})
    attributes = { record_type: 'custom_tag', tag: 'touched', candidate_key: 'n/a' }.merge attributes
    record_tag = RecordTag.find_or_create_by(attributes)
    record_tag.update(record_id: record_tag.id) if record_tag.record_id == 0 # notice validation above, this just ensures that we don't violate the table constraint.
  end

  def self.generate_seeds
    self.generate_seed_for_models(self.seed_order)
  end

  def self.generate_seed_for_models(models)
    time = Time.now
    seed_files = []

    models.each do |model|
      seed_files << self.generate_update_seed(model, time.strftime('%Y%m%d%H%M%S'))
      time += 1.second
    end

    models.reverse.each do |model|
      seed_files << self.generate_destroy_seed(model, time.strftime('%Y%m%d%H%M%S'))
      time += 1.second
    end

    RecordTag.where(record_type: models.map(&:name)).destroy_all
    seed_files.compact
  end

  def self.generate_seed_for_model(model)
    time = Time.now
    seed_files = []
    seed_files << self.generate_update_seed(model, time.strftime('%Y%m%d%H%M%S'))
    seed_files << self.generate_destroy_seed(model, (time + 1.second).strftime('%Y%m%d%H%M%S'))
    RecordTag.where(record_type: model.name).destroy_all
    seed_files.compact
  end

  private

  def self.generate_update_seed(model, timestamp)
    touched_tags = RecordTag.where(record_type: model.name, tag: ['created', 'updated']).includes(:record)
    return nil if touched_tags.empty?

    base_file_path = File.join(Rails.root, 'db', 'packs') #TODO throw this into a config
    seed_path = File.join(base_file_path, "#{timestamp}_seed_#{model.class_name.underscore.pluralize}_updates.rb")

    File.open(seed_path, 'w') do |f|
      f.puts "class Seed#{model.class_name.pluralize}Updates"
      f.puts '  def up'
      f.puts '    # Generated by RecordTag.generate_seed'

      touched_tags.each do |tag|
        f.puts "\n"
        f.puts "    # Generating seed for #{tag.tag.upcase} tag."
        f.print  "    record = #{model.name}.find_by("
        f.print self.print_candidate_key(tag.record)
        f.puts  ')'

        f.print  "    record = #{model.name}.find_or_initialize_by("
        f.print self.attribute_string_from_hash(model, tag.candidate_key)
        f.puts ') if record.nil?'

        f.print "    record.update!("
        column_hash = {}
        model.attribute_names.reject { |col| col == model.primary_key }
                             .each { |col| column_hash[col] = tag.record.send(col) }
        f.print self.attribute_string_from_hash(model, column_hash)
        f.puts ')'
      end

      f.puts '  end'
      f.puts 'end'
    end

    seed_path
  end

  def self.generate_destroy_seed(model, timestamp)
    destroyed_tags = RecordTag.where(record_type: model.name, tag: 'destroyed')
    return nil if destroyed_tags.empty?

    base_file_path = File.join(Rails.root, 'db', 'packs') #TODO throw this into a config
    seed_path = File.join(base_file_path, "#{timestamp}_seed_#{model.class_name.underscore.pluralize}_destroys.rb")

    File.open(seed_path, 'w') do |f|
      f.puts "class Seed#{model.class_name.pluralize}Destroys"
      f.puts '  def up'
      f.puts '    # Generated by RecordTag.generate_seed'

      destroyed_tags.map(&:candidate_key).each do |record_candidate_key|
        f.puts "\n"
        f.print "    record = #{model.name}.find_by("
        f.puts "#{self.attribute_string_from_hash(model, record_candidate_key)})"
        f.puts "    record.try(:destroy)"
      end

      f.puts '  end'
      f.puts 'end'
    end

    seed_path
  end

  def self.print_candidate_key(record)
    candidate_key = record.class.try(:candidate_key) || :reference
    candidate_key = [candidate_key] unless candidate_key.is_a? Array
    raise RecordTagExceptions::InvalidCandidateKeyForRecord unless self.record_has_attributes?(record, candidate_key)

    candidate_key_hash = {}
    candidate_key.each { |key| candidate_key_hash[key] = record.send(key) }
    self.attribute_string_from_hash(record.class, candidate_key_hash)
  end

  def self.attribute_string_from_hash(model, column_hash)
    column_hash.symbolize_keys!
    formatted_candidate_key = []

    column_hash.each do |k, v|
      reflection = self.find_foreign_key_relation(model, k)

      if reflection && v.present?
        associated_model = if reflection.polymorphic?
          column_hash[reflection.foreign_type.to_sym].constantize
        else
          reflection.klass
        end

        if associated_model.ancestors.include?(Taggable) || associated_model.respond_to?(:candidate_key)
          associated_record = associated_model.find_by(associated_model.primary_key => v)
          to_add = "#{reflection.name}: #{associated_model.name}.find_by("

          if associated_record.present?
            to_add += "#{self.print_candidate_key(associated_record)})"
          else # likely this record was destroyed, so we should have a tag for it
            tag = RecordTag.find_by(record_type: associated_model.name, record_id: v)
            raise RecordTagExceptions::RecordNotFound, "while processing #{column_hash}" if tag.nil?
            to_add += "#{self.attribute_string_from_hash(associated_model, tag.candidate_key)})"
          end

          formatted_candidate_key << to_add
          next
        end
      end

      formatted_candidate_key << "#{k}: #{self.primitive_string(v)}"
    end

    formatted_candidate_key.join(', ')
  end

  def self.find_foreign_key_relation(model, accessor)
    model.reflect_on_all_associations.find do |r|
      begin
        r.foreign_key.to_sym == accessor.to_sym
      rescue NameError
        false
      end
    end
  end

  def self.record_has_attributes?(record, attributes)
    attributes.each do |attribute|
      return false unless record.has_attribute?(attribute)
    end

    true
  end

  def self.primitive_string(p)
    if p.nil?
      'nil'
    elsif p.is_a? String
      "'#{p}'"
    elsif p.is_a? Time
      "Time.parse('#{p}')"
    else
      "#{p}"
    end
  end

  def self.format_error_message(existing_tag, new_tag, record_to_store)
    "found an existing '#{existing_tag}' tag for record while tagging, '#{new_tag}' - #{record_to_store}"
  end
end