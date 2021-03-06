#
# A model with the ability to add and remove membership.  Membership changes may require
# work to be done on distributed resources associated with this model, or on child resources.
#
module Membership
  extend ActiveSupport::Concern
  include AccessControlled

  included do
    validate :explicit_members_are_limited
  end

  def has_member?(o)
    members.include?(o)
  end

  def role_for(member_or_id)
    id = member_or_id.respond_to?(:_id) ? member_or_id._id : member_or_id
    members.inject(default_role){ |r, m| return (m.role || r) if m._id === id; r }
    nil
  end

  def default_role
    self.class.default_role
  end

  def member_ids
    members.map(&:_id)
  end

  def add_members(*args)
    from = args.pop if args.length > 1 && args.last.is_a?(Array)
    role = args.pop if args.last.is_a?(Symbol) && args.length > 1
    changing_members do
      args.flatten(1).map do |arg|
        m = self.class.to_member(arg)
        m.add_grant(role || m.role || default_role, from) if from || !m.role?
        if exists = members.find(m._id) rescue nil
          exists.merge(m)
        else
          members.push(m)
        end
      end
    end
    self
  end

  def remove_members(*args)
    from = args.pop if args.last.is_a?(Symbol) || (args.length > 1 && args.last.is_a?(Array))
    return self if args.empty?
    changing_members do
      Array(members.find(*args)).each{ |m| m.delete if m.remove_grant(from) }
    end
    self
  end

  def reset_members
    changing_members do
      members.clear
    end
    self
  end

  # FIXME
  # Mongoid has no support for adding/removing embedded relations in bulk in 3.0.
  # Until that is available, provide a block form that signals that the set of operations
  # is intended to be deferred until a save on the document is called, and track
  # the ids that are removed and added
  #
  # FIXME
  # does not handle _id collisions across types.  May or may not want to resolve.
  #
  def changing_members(&block)
    _assigning do
      ids = member_ids
      instance_eval(&block)
      new_ids = member_ids

      added, removed = (new_ids - ids), (ids - new_ids)

      @original_members ||= ids
      @members_added ||= []; @members_removed ||= []
      @members_added -= removed; @members_removed -= added
      @members_added.concat(added).uniq!; @members_removed.concat(removed & @original_members).uniq!
    end
    self
  end

  def has_member_changes?
    @members_added.present? || @members_removed.present? || members.any?(&:role_changed?)
  end

  def explicit_members_are_limited
    max = Rails.configuration.openshift[:max_members_per_resource]
    if members.target.count(&:explicit_role?) > max
      errors.add(:members, "You are limited to #{max} members per #{self.class.model_name.humanize.downcase}")
    end
  end

  protected
    def parent_membership_relation
      relations.values.find{ |r| r.macro == :belongs_to }
    end

    def default_members
      if parent = parent_membership_relation
        p = send(parent.name)
        p.inherit_membership.each{ |m| m.clear.add_grant(m.role || default_role, parent.name) } if p
      end || []
    end

    #
    # The list of member ids that changed on the object.  The change_members op
    # is best if it is consistent on all access controlled classes
    #
    def members_changed(added, removed, changed_roles)
      queue_op(:change_members, added: added.presence, removed: removed.presence, changed: changed_roles.presence)
    end

    #
    # Helper method for processing role changes
    #
    def change_member_roles(changed_roles, source)
      changed_roles.each do |arr|
        if m = members.detect{ |m| m._id == arr.first }
          m.update_grant(arr.last, source)
        end
      end
      self
    end

    # FIXME create a standard pending operations model mixin that uniformly handles queueing on all type
    def queue_op(op, args)
      (relations['pending_ops'] ? pending_ops : pending_op_groups).build(:op_type => op, :state => :init, :args => args.stringify_keys)
    end

    def handle_member_changes
      if persisted?
        changing_members{ members.concat(default_members) } if members.empty?
        if has_member_changes?
          changed_roles = members.select{ |m| m.role_changed? && !(@members_added && @members_added.include?(m._id)) }.map{ |m| [m._id].concat(m.role_change) }
          added_roles = members.select{ |m| @members_added && @members_added.include?(m._id) }.map{ |m| [m._id, m.role, m._type, m.name] }
          members_changed(added_roles, @members_removed, changed_roles)
          @original_members, @members_added, @members_removed = nil
        end
      else
        members.concat(default_members)
      end
      @_children = nil # ensure the child collection is recalculated
      true
    end

  module ClassMethods
    def has_members(opts={})
      embeds_many :members, as: :access_controlled, cascade_callbacks: true
      before_save :handle_member_changes

      index 'members._id' => 1

      class_attribute :default_role, instance_accessor: false

      if through = opts[:through].to_s.presence
        define_method :parent_membership_relation do
          relations[through]
        end
      end
      self.default_role = opts[:default_role] || :view
    end

    #
    # Overrides AccessControlled#accessible
    #
    def accessible(to)
      criteria =
        if Rails.configuration.openshift[:membership_enabled]
          where(:'members._id' => to.is_a?(String) ? to : to._id)
        elsif respond_to? :legacy_accessible
          legacy_accessible(to)
        else
          queryable
        end
      scope_limited(to, criteria)
    end

    def to_member(arg)
      if Member === arg
        arg
      else
        if arg.respond_to?(:as_member)
          arg.as_member
        elsif arg.is_a?(Array)
          Member.new{ |m| m._id = arg[0]; m.role = arg[1]; m._type = arg[2]; m.name = arg[3] }
        else
          Member.new{ |m| m._id = arg }
        end
      end
    end
  end
end