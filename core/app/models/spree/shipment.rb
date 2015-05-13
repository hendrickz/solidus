require 'ostruct'

module Spree
  class Shipment < Spree::Base
    belongs_to :order, class_name: 'Spree::Order', touch: true, inverse_of: :shipments

    belongs_to :order, class_name: 'Spree::Order', touch: true, inverse_of: :shipments
    belongs_to :address, class_name: 'Spree::Address', inverse_of: :shipments
    belongs_to :stock_location, class_name: 'Spree::StockLocation'

    has_many :adjustments, as: :adjustable, inverse_of: :adjustable, dependent: :delete_all
    has_many :inventory_units, dependent: :destroy, inverse_of: :shipment
    has_many :shipping_rates, -> { order('cost ASC') }, dependent: :delete_all
    has_many :shipping_methods, through: :shipping_rates
    has_many :state_changes, as: :stateful
    has_many :cartons, -> { uniq }, through: :inventory_units

    after_save :update_adjustments

    before_validation :set_cost_zero_when_nil

    attr_accessor :special_instructions

    accepts_nested_attributes_for :address
    accepts_nested_attributes_for :inventory_units

    make_permalink field: :number, length: 11, prefix: 'H'

    scope :pending, -> { with_state('pending') }
    scope :ready,   -> { with_state('ready') }
    scope :shipped, -> { with_state('shipped') }
    scope :trackable, -> { where("tracking IS NOT NULL AND tracking != ''") }
    scope :with_state, ->(*s) { where(state: s) }
    # sort by most recent shipped_at, falling back to created_at. add "id desc" to make specs that involve this scope more deterministic.
    scope :reverse_chronological, -> { order('coalesce(spree_shipments.shipped_at, spree_shipments.created_at) desc', id: :desc) }

    # shipment state machine (see http://github.com/pluginaweek/state_machine/tree/master for details)
    state_machine initial: :pending, use_transactions: false do
      event :ready do
        transition from: :pending, to: :shipped, if: :can_transition_from_pending_to_shipped?
        transition from: :pending, to: :ready, if: :can_transition_from_pending_to_ready?
      end

      event :pend do
        transition from: :ready, to: :pending
      end

      event :ship do
        transition from: [:ready, :canceled], to: :shipped
      end
      after_transition to: :shipped, do: :after_ship

      event :cancel do
        transition to: :canceled, from: [:pending, :ready]
      end
      after_transition to: :canceled, do: :after_cancel

      event :resume do
        transition from: :canceled, to: :ready, if: :can_transition_from_canceled_to_ready?
        transition from: :canceled, to: :pending
      end
      after_transition from: :canceled, to: [:pending, :ready, :shipped], do: :after_resume

      after_transition do |shipment, transition|
        shipment.state_changes.create!(
          previous_state: transition.from,
          next_state:     transition.to,
          name:           'shipment',
        )
      end
    end

    def can_transition_from_pending_to_shipped?
      !requires_shipment?
    end

    def can_transition_from_pending_to_ready?
      order.can_ship? && !inventory_units.any?(&:backordered?) && order.paid?
    end

    def can_transition_from_canceled_to_ready?
      can_transition_from_pending_to_ready?
    end

    extend DisplayMoney
    money_methods :cost, :discounted_cost, :final_price, :item_cost
    alias display_amount display_cost

    def add_shipping_method(shipping_method, selected = false)
      shipping_rates.create(shipping_method: shipping_method, selected: selected, cost: cost)
    end

    def after_cancel
      manifest.each { |item| manifest_restock(item) }
    end

    def after_resume
      manifest.each { |item| manifest_unstock(item) }
    end

    def backordered?
      inventory_units.any? { |inventory_unit| inventory_unit.backordered? }
    end

    def currency
      order ? order.currency : Spree::Config[:currency]
    end

    def discounted_cost
      cost + promo_total
    end
    alias discounted_amount discounted_cost


    def editable_by?(user)
      !shipped?
    end

    def final_price
      cost + adjustment_total
    end

    def final_price_with_items
      item_cost + final_price
    end

    def finalize!
      InventoryUnit.finalize_units!(inventory_units)
      manifest.each { |item| manifest_unstock(item) }
    end

    def include?(variant)
      inventory_units_for(variant).present?
    end

    def inventory_units_for(variant)
      inventory_units.where(variant_id: variant.id)
    end

    def inventory_units_for_item(line_item, variant = nil)
      inventory_units.where(line_item_id: line_item.id, variant_id: line_item.variant.id || variant.id)
    end

    def item_cost
      line_items.map(&:final_amount).sum
    end

    def line_items
      inventory_units.includes(:line_item).map(&:line_item).uniq
    end

    def process_order_payments
      pending_payments =  order.pending_payments
                            .sort_by(&:uncaptured_amount).reverse

      shipment_to_pay = final_price_with_items
      payments_amount = 0

      payments_pool = pending_payments.each_with_object([]) do |payment, pool|
        break if payments_amount >= shipment_to_pay
        payments_amount += payment.uncaptured_amount
        pool << payment
      end

      payments_pool.each do |payment|
        capturable_amount = if payment.amount >= shipment_to_pay
                              shipment_to_pay
                            else
                              payment.amount
                            end

        cents = (capturable_amount * 100).to_i
        payment.capture!(cents)
        shipment_to_pay -= capturable_amount
      end
    end

    def line_items
      inventory_units.includes(:line_item).map(&:line_item).uniq
    end

    def ready_or_pending?
      self.ready? || self.pending?
    end

    def refresh_rates
      return shipping_rates if shipped? || order.completed?
      return [] unless can_get_rates?

      # StockEstimator.new assigment below will replace the current shipping_method
      original_shipping_method_id = shipping_method.try!(:id)

      new_rates = Stock::Estimator.new(order).shipping_rates(to_package)

      # If one of the new rates matches the previously selected shipping
      # method, select that instead of the default provided by the estimator.
      # Otherwise, keep the default.
      selected_rate = new_rates.detect{ |rate| rate.shipping_method_id == original_shipping_method_id }
      if selected_rate
        new_rates.each do |rate|
          rate.selected = (rate == selected_rate)
        end
      end

      self.shipping_rates = new_rates
      self.save!

      shipping_rates
    end

    def selected_shipping_rate
      shipping_rates.detect(&:selected?)
    end

    def manifest
      @manifest ||= Spree::ShippingManifest.new(inventory_units: inventory_units).items
    end

    def selected_shipping_rate_id
      selected_shipping_rate.try(:id)
    end

    def selected_shipping_rate_id=(id)
      shipping_rates.update_all(selected: false)
      shipping_rates.update(id, selected: true)
      self.save!
    end

    # Determines the appropriate +state+ according to the following logic:
    #
    # canceled   if order is canceled
    # pending    unless order is complete and +order.payment_state+ is +paid+
    # shipped    if already shipped (ie. does not change the state)
    # ready      all other cases
    def determine_state(order)
      return 'canceled' if order.canceled?
      return 'pending' unless order.can_ship?
      return 'pending' if inventory_units.any? &:backordered?
      return 'shipped' if state == 'shipped'
      order.paid? ? 'ready' : 'pending'
    end

    def set_up_inventory(state, variant, order, line_item)
      self.inventory_units.create(
        state: state,
        variant_id: variant.id,
        order_id: order.id,
        line_item_id: line_item.id
      )
    end

    def shipped=(value)
      return unless value == '1' && shipped_at.nil?
      self.shipped_at = Time.now
    end

    def shipping_method
      selected_shipping_rate.try(:shipping_method) || shipping_rates.first.try(:shipping_method)
    end

    def tax_category
      selected_shipping_rate.try(:tax_rate).try(:tax_category)
    end

    # Only one of either included_tax_total or additional_tax_total is set
    # This method returns the total of the two. Saves having to check if
    # tax is included or additional.
    def tax_total
      included_tax_total + additional_tax_total
    end

    def to_package
      package = Stock::Package.new(stock_location)
      inventory_units.includes(:variant).joins(:variant).group_by(&:state).each do |state, state_inventory_units|
        package.add_multiple state_inventory_units, state.to_sym
      end
      package
    end

    def to_param
      number
    end

    def tracking_url
      @tracking_url ||= shipping_method.build_tracking_url(tracking)
    end

    def update_amounts
      if selected_shipping_rate
        self.update_columns(
          cost: selected_shipping_rate.cost,
          adjustment_total: adjustments.additional.map(&:update!).compact.sum,
          updated_at: Time.now,
        )
      end
    end

    # Update Shipment and make sure Order states follow the shipment changes
    def update_attributes_and_order(params = {})
      if self.update_attributes params
        if params.has_key? :selected_shipping_rate_id
          # Changing the selected Shipping Rate won't update the cost (for now)
          # so we persist the Shipment#cost before calculating order shipment
          # total and updating payment state (given a change in shipment cost
          # might change the Order#payment_state)
          self.update_amounts

          order.updater.update_shipment_total
          order.updater.update_payment_state

          # Update shipment state only after order total is updated because it
          # (via Order#paid?) affects the shipment state (YAY)
          self.update_columns(
            state: determine_state(order),
            updated_at: Time.now
          )

          # And then it's time to update shipment states and finally persist
          # order changes
          order.updater.update_shipment_state
          order.updater.persist_totals
        end

        true
      end
    end

    # Updates various aspects of the Shipment while bypassing any callbacks.  Note that this method takes an explicit reference to the
    # Order object.  This is necessary because the association actually has a stale (and unsaved) copy of the Order and so it will not
    # yield the correct results.
    def update!(order)
      old_state = state
      new_state = determine_state(order)
      update_columns(
        state: new_state,
        updated_at: Time.now,
      )
      after_ship if new_state == 'shipped' and old_state != 'shipped'
    end

    def transfer_to_location(variant, quantity, stock_location)
      if quantity <= 0
        raise ArgumentError
      end

      transaction do
        new_shipment = order.shipments.create!(stock_location: stock_location)

        order.contents.remove(variant, quantity, {shipment: self})
        order.contents.add(variant, quantity, {shipment: new_shipment})

        refresh_rates
        save!
        new_shipment.save!
      end
    end

    def transfer_to_shipment(variant, quantity, shipment_to_transfer_to)
      quantity_already_shipment_to_transfer_to = shipment_to_transfer_to.manifest.find{|mi| mi.line_item.variant == variant}.try(:quantity) || 0
      final_quantity = quantity + quantity_already_shipment_to_transfer_to

      if (quantity <= 0 || self == shipment_to_transfer_to)
        raise ArgumentError
      end

      transaction do
        order.contents.remove(variant, quantity, {shipment: self})
        order.contents.add(variant, quantity, {shipment: shipment_to_transfer_to})

        refresh_rates
        save!
        shipment_to_transfer_to.refresh_rates
        shipment_to_transfer_to.save!
      end
    end

    def requires_shipment?
      !stock_location || stock_location.fulfillable?
    end

    private

      def after_ship
        order.shipping.ship_shipment(self)
      end

      def can_get_rates?
        order.ship_address && order.ship_address.valid?
      end

      def manifest_restock(item)
        if item.states["on_hand"].to_i > 0
         stock_location.restock item.variant, item.states["on_hand"], self
        end

        if item.states["backordered"].to_i > 0
          stock_location.restock_backordered item.variant, item.states["backordered"]
        end
      end

      def manifest_unstock(item)
        stock_location.unstock item.variant, item.quantity, self
      end

      def recalculate_adjustments
        Spree::ItemAdjustments.new(self).update
      end

      def set_cost_zero_when_nil
        self.cost = 0 unless self.cost
      end

      def update_adjustments
        if cost_changed? && state != 'shipped'
          recalculate_adjustments
        end
      end

  end
end
