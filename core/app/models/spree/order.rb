require 'spree/core/validators/email'
require 'spree/order/checkout'

module Spree
  class Order < Spree::Base
    PAYMENT_STATES = %w(balance_due credit_owed failed paid void)
    SHIPMENT_STATES = %w(backorder canceled partial pending ready shipped arrived done)

    include Spree::Order::Checkout
    include Spree::Order::CurrencyUpdater
    include Spree::Order::Payments
    include Spree::Order::StoreCredit
    include Spree::Core::NumberGenerator.new(prefix: 'R')
    include Spree::Core::TokenGenerator

    include Spree::Promotionable

    include NumberAsParam

    extend Spree::DisplayMoney
    money_methods :outstanding_balance, :item_total,           :adjustment_total,
                  :included_tax_total,  :additional_tax_total, :tax_total,
                  :shipment_total,      :promo_total,          :total,
                  :total_to_be_paid

    alias display_ship_total display_shipment_total
    alias_attribute :ship_total, :shipment_total

    MONEY_THRESHOLD  = 100_000_000
    MONEY_VALIDATION = {
      presence:     true,
      numericality: {
        greater_than: -MONEY_THRESHOLD,
        less_than:     MONEY_THRESHOLD,
        allow_blank:   true
      },
      format:       { with: /\A-?\d+(?:\.\d{1,2})?\z/, allow_blank: true }
    }.freeze

    POSITIVE_MONEY_VALIDATION = MONEY_VALIDATION.deep_dup.tap do |validation|
      validation.fetch(:numericality)[:greater_than_or_equal_to] = 0
    end.freeze

    NEGATIVE_MONEY_VALIDATION = MONEY_VALIDATION.deep_dup.tap do |validation|
      validation.fetch(:numericality)[:less_than_or_equal_to] = 0
    end.freeze

    checkout_flow do
      go_to_state :address
      go_to_state :delivery
      go_to_state :payment, if: ->(order) { order.payment? || order.payment_required? }
      go_to_state :confirm, if: ->(order) { order.confirmation_required? }
      go_to_state :complete
      remove_transition from: :delivery, to: :confirm
    end

    self.whitelisted_ransackable_associations = %w[shipments user promotions bill_address ship_address line_items]
    self.whitelisted_ransackable_attributes = %w[completed_at email number state payment_state shipment_state total considered_risky]

    attr_reader :coupon_code
    attr_accessor :temporary_address, :temporary_credit_card

    if Spree.user_class
      belongs_to :user, class_name: Spree.user_class.to_s, optional: true
      belongs_to :created_by, class_name: Spree.user_class.to_s, optional: true
      belongs_to :approver, class_name: Spree.user_class.to_s, optional: true
      belongs_to :canceler, class_name: Spree.user_class.to_s, optional: true
    else
      belongs_to :user, optional: true
      belongs_to :created_by, optional: true
      belongs_to :approver, optional: true
      belongs_to :canceler, optional: true
    end

    belongs_to :bill_address, foreign_key: :bill_address_id, class_name: 'Spree::Address'
    alias_attribute :billing_address, :bill_address

    belongs_to :ship_address, foreign_key: :ship_address_id, class_name: 'Spree::Address'
    alias_attribute :shipping_address, :ship_address

    belongs_to :store, class_name: 'Spree::Store'

    with_options dependent: :destroy do
      has_many :state_changes, as: :stateful
      has_many :line_items, -> { order(:created_at) }, inverse_of: :order
      has_many :payments
      has_many :payment_confirmations
      has_many :return_authorizations, inverse_of: :order
      has_many :adjustments, -> { order(:created_at) }, as: :adjustable
    end
    has_many :reimbursements, inverse_of: :order
    has_many :line_item_adjustments, through: :line_items, source: :adjustments
    has_many :inventory_units, inverse_of: :order
    has_many :variants, through: :line_items
    has_many :products, through: :variants
    has_many :refunds, through: :payments
    has_many :all_adjustments,
             class_name: 'Spree::Adjustment',
             foreign_key: :order_id,
             dependent: :destroy,
             inverse_of: :order

    has_many :order_promotions, class_name: 'Spree::OrderPromotion'
    has_many :promotions, through: :order_promotions, class_name: 'Spree::Promotion'

    has_many :shipments, dependent: :destroy, inverse_of: :order do
      def states
        pluck(:state).uniq
      end
    end
    has_many :shipment_adjustments, through: :shipments, source: :adjustments

    accepts_nested_attributes_for :line_items
    accepts_nested_attributes_for :bill_address
    accepts_nested_attributes_for :ship_address
    accepts_nested_attributes_for :payments, reject_if: :credit_card_nil_payment?
    accepts_nested_attributes_for :shipments

    # Needs to happen before save_permalink is called
    before_validation :set_currency
    before_validation :clone_billing_address, if: :use_billing?
    attr_accessor :use_billing, :payment_proof

    before_create :create_token
    before_create :link_by_email
    before_update :homogenize_line_item_currencies, if: :currency_changed?

    with_options presence: true do
      validates :number, length: { maximum: 32, allow_blank: true }, uniqueness: { allow_blank: true }
      validates :email, length: { maximum: 254, allow_blank: true }, email: { allow_blank: true }, if: :require_email
      validates :item_count, numericality: { greater_than_or_equal_to: 0, less_than: 2**31, only_integer: true, allow_blank: true }
    end
    validates :payment_state,        inclusion:    { in: PAYMENT_STATES, allow_blank: true }
    validates :shipment_state,       inclusion:    { in: SHIPMENT_STATES, allow_blank: true }
    validates :item_total,           POSITIVE_MONEY_VALIDATION
    validates :adjustment_total,     MONEY_VALIDATION
    validates :included_tax_total,   POSITIVE_MONEY_VALIDATION
    validates :additional_tax_total, POSITIVE_MONEY_VALIDATION
    validates :payment_total,        MONEY_VALIDATION
    validates :shipment_total,       MONEY_VALIDATION
    validates :promo_total,          NEGATIVE_MONEY_VALIDATION
    validates :total,                MONEY_VALIDATION

    delegate :update_totals, :persist_totals, to: :updater
    delegate :merge!, to: :merger
    delegate :firstname, :lastname, to: :bill_address, prefix: true, allow_nil: true

    class_attribute :update_hooks
    self.update_hooks = Set.new

    class_attribute :line_item_comparison_hooks
    self.line_item_comparison_hooks = Set.new

    scope :created_between, ->(start_date, end_date) { where(created_at: start_date..end_date) }
    scope :completed_between, ->(start_date, end_date) { where(completed_at: start_date..end_date) }
    scope :complete, -> { where.not(completed_at: nil) }
    scope :incomplete, -> { where(completed_at: nil) }

    # shows completed orders first, by their completed_at date, then uncompleted orders by their created_at
    scope :reverse_chronological, -> { order('spree_orders.completed_at IS NULL', completed_at: :desc, created_at: :desc) }

    # Use this method in other gems that wish to register their own custom logic
    # that should be called after Order#update
    def self.register_update_hook(hook)
      update_hooks.add(hook)
    end

    def self.exort_attributes_for(type)
      if type.eql?('xlsx')
        no_need_to_show_attributes = [:image, :photo]
        attribute_names.map(&:to_sym).reject { |a| no_need_to_show_attributes.include?(a) }
        # [:created_at]
      end
    end

    # Use this method in other gems that wish to register their own custom logic
    # that should be called when determining if two line items are equal.
    def self.register_line_item_comparison_hook(hook)
      line_item_comparison_hooks.add(hook)
    end

    # For compatiblity with Calculator::PriceSack
    def amount
      line_items.inject(0.0) { |sum, li| sum + li.amount }
    end

    def total_to_be_paid
      if self.payments.present?
        unique_code = self.payments.last.source.amount_identifier
      else
        unique_code = rand(999)
      end
      if self.has_promo?
        total_price = self.display_total_after_discount + self.adjustments.eligible.sum(&:amount) + self.shipment_total.to_i
      else
        if self.adjustments.present?
          total_price = self.display_total_after_discount + self.shipment_total.to_i
        else
          total_price = self.display_total_after_discount
        end
      end
      @total_to_be_paid ||= total_price + unique_code
    end

    # Sum of all line item amounts pre-tax
    def pre_tax_item_amount
      line_items.to_a.sum(&:pre_tax_amount)
    end

    def currency
      self[:currency] || Spree::Config[:currency]
    end

    def shipping_discount
      shipment_adjustments.non_tax.eligible.sum(:amount) * - 1
    end

    def completed?
      completed_at.present?
    end

    # Indicates whether or not the user is allowed to proceed to checkout.
    # Currently this is implemented as a check for whether or not there is at
    # least one LineItem in the Order.  Feel free to override this logic in your
    # own application if you require additional steps before allowing a checkout.
    def checkout_allowed?
      line_items.exists?
    end

    # Is this a free order in which case the payment step should be skipped
    def payment_required?
      total.to_f > 0.0
    end

    # If true, causes the confirmation step to happen during the checkout process
    def confirmation_required?
      Spree::Config[:always_include_confirm_step] ||
        payments.valid.map(&:payment_method).compact.any?(&:payment_profiles_supported?) ||
        # Little hacky fix for #4117
        # If this wasn't here, order would transition to address state on confirm failure
        # because there would be no valid payments any more.
        confirm?
    end

    def backordered?
      shipments.any?(&:backordered?)
    end

    # Returns the relevant zone (if any) to be used for taxation purposes.
    # Uses default tax zone unless there is a specific match
    def tax_zone
      @tax_zone ||= Zone.match(tax_address) || Zone.default_tax
    end

    # Returns the address for taxation based on configuration
    def tax_address
      Spree::Config[:tax_using_ship_address] ? ship_address : bill_address
    end

    def updater
      @updater ||= OrderUpdater.new(self)
    end

    def update_with_updater!
      updater.update
    end

    def merger
      @merger ||= Spree::OrderMerger.new(self)
    end

    def clone_billing_address
      if bill_address && ship_address.nil?
        self.ship_address = bill_address.clone
      else
        ship_address.attributes = bill_address.attributes.except('id', 'updated_at', 'created_at')
      end
      true
    end

    def allow_cancel?
      return false if !completed? || canceled?
      shipment_state.nil? || %w{ready backorder pending}.include?(shipment_state)
    end

    def all_inventory_units_returned?
      inventory_units.all?(&:returned?)
    end

    def contents
      @contents ||= Spree::OrderContents.new(self)
    end

    # Associates the specified user with the order.
    def associate_user!(user, override_email = true)
      self.user           = user
      self.email          = user.email if override_email
      self.created_by   ||= user
      self.bill_address ||= user.bill_address
      self.ship_address ||= user.ship_address

      changes = slice(:user_id, :email, :created_by_id, :bill_address_id, :ship_address_id)

      # immediately persist the changes we just made, but don't use save
      # since we might have an invalid address associated
      self.class.unscoped.where(id: self).update_all(changes)
    end

    def quantity_of(variant, options = {})
      line_item = find_line_item_by_variant(variant, options)
      line_item ? line_item.quantity : 0
    end

    def find_line_item_by_variant(variant, options = {})
      line_items.detect do |line_item|
        line_item.variant_id == variant.id &&
          line_item_options_match(line_item, options)
      end
    end

    # This method enables extensions to participate in the
    # "Are these line items equal" decision.
    #
    # When adding to cart, an extension would send something like:
    # params[:product_customizations]={...}
    #
    # and would provide:
    #
    # def product_customizations_match
    def line_item_options_match(line_item, options)
      return true unless options

      line_item_comparison_hooks.all? do |hook|
        send(hook, line_item, options)
      end
    end

    # Creates new tax charges if there are any applicable rates. If prices already
    # include taxes then price adjustments are created instead.
    def create_tax_charge!
      Spree::TaxRate.adjust(self, line_items)
      Spree::TaxRate.adjust(self, shipments) if shipments.any?
    end

    def create_shipment_tax_charge!
      Spree::TaxRate.adjust(self, shipments) if shipments.any?
    end

    def update_line_item_prices!
      transaction do
        line_items.each(&:update_price)
        save!
      end
    end

    def outstanding_balance
      if canceled?
        -1 * payment_total
      elsif refunds.exists?
        # If refund has happened add it back to total to prevent balance_due payment state
        # See: https://github.com/spree/spree/issues/6229 & https://github.com/spree/spree/issues/8136
        total - (payment_total + refunds.sum(:amount))
      else
        total - payment_total
      end
    end

    def outstanding_balance?
      outstanding_balance != 0
    end

    def name
      if (address = bill_address || ship_address)
        address.full_name
      end
    end

    def can_ship?
      complete? || resumed? || awaiting_return? || returned?
    end

    def credit_cards
      credit_card_ids = payments.from_credit_card.pluck(:source_id).uniq
      CreditCard.where(id: credit_card_ids)
    end

    def valid_credit_cards
      credit_card_ids = payments.from_credit_card.valid.pluck(:source_id).uniq
      CreditCard.where(id: credit_card_ids)
    end

    # Finalizes an in progress order after checkout is complete.
    # Called after transition to complete state when payments will have been processed
    def finalize!
      # lock all adjustments (coupon promotions, etc.)
      all_adjustments.each(&:close)

      # update payment and shipment(s) states, and save
      updater.update_payment_state
      shipments.each do |shipment|
        shipment.update!(self)
        shipment.finalize!
      end

      updater.update_shipment_state
      save!
      updater.run_hooks

      touch :completed_at

      deliver_order_confirmation_email unless confirmation_delivered?

      consider_risk
    end

    def fulfill!
      shipments.each { |shipment| shipment.update!(self) if shipment.persisted? }
      updater.update_shipment_state
      save!
    end

    def deliver_order_confirmation_email
      # OrderMailer.confirm_email(id).deliver_later
      OrderMailer.confirm_email(id).deliver
      update_column(:confirmation_delivered, true)
    end

    # Helper methods for shipment steps
    def pending?
      shipment_state == 'pending'
    end

    def backorder?
      shipment_state == 'backorder'
    end

    def canceled?
      shipment_state == 'canceled'
    end

    def ready?
      shipment_state == 'ready'
    end

    def shipped?
      shipment_state == 'shipped'
    end

    def arrived?
      shipment_state == 'arrived'
    end

    def done?
      shipment_state == 'done'
    end

    # Helper methods for checkout steps
    def paid?
      payment_state == 'paid' || payment_state == 'credit_owed'
    end

    def available_payment_methods
      @available_payment_methods ||= collect_payment_methods
    end

    def insufficient_stock_lines
      line_items.select(&:insufficient_stock?)
    end

    ##
    # Check to see if any line item variants are discontinued.
    # If so add error and restart checkout.
    def ensure_line_item_variants_are_not_discontinued
      if line_items.any? { |li| !li.variant || li.variant.discontinued? }
        restart_checkout_flow
        errors.add(:base, Spree.t(:discontinued_variants_present))
        false
      else
        true
      end
    end

    def ensure_line_items_are_in_stock
      if insufficient_stock_lines.present?
        restart_checkout_flow
        errors.add(:base, Spree.t(:insufficient_stock_lines_present))
        false
      else
        true
      end
    end

    def empty!
      if completed?
        raise Spree.t(:cannot_empty_completed_order)
      else
        line_items.destroy_all
        updater.update_item_count
        adjustments.destroy_all
        shipments.destroy_all
        state_changes.destroy_all
        order_promotions.destroy_all

        update_totals
        persist_totals
        restart_checkout_flow
        self
      end
    end

    def has_step?(step)
      checkout_steps.include?(step)
    end

    def state_changed(name)
      state = "#{name}_state"
      if persisted?
        old_state = send("#{state}_was")
        new_state = send(state)
        unless old_state == new_state
          state_changes.create(
            previous_state: old_state,
            next_state:     new_state,
            name:           name,
            user_id:        user_id
          )
        end
      end
    end

    def coupon_code=(code)
      @coupon_code = begin
                       code.strip.downcase
                     rescue
                       nil
                     end
    end

    def can_add_coupon?
      Spree::Promotion.order_activatable?(self)
    end

    def shipped?
      %w(partial shipped).include?(shipment_state)
    end

    def create_proposed_shipments
      all_adjustments.shipping.delete_all

      shipment_ids = shipments.map(&:id)
      StateChange.where(stateful_type: 'Spree::Shipment', stateful_id: shipment_ids).delete_all
      ShippingRate.where(shipment_id: shipment_ids).delete_all

      shipments.delete_all

      # Inventory Units which are not associated to any shipment (unshippable)
      # and are not returned or shipped should be deleted
      inventory_units.on_hand_or_backordered.delete_all

      self.shipments = Spree::Stock::Coordinator.new(self).shipments
    end

    def apply_free_shipping_promotions
      Spree::PromotionHandler::FreeShipping.new(self).activate
      shipments.each { |shipment| Adjustable::AdjustmentsUpdater.update(shipment) }
      updater.update_shipment_total
      persist_totals
    end

    # Clean shipments and make order back to address state
    #
    # At some point the might need to force the order to transition from address
    # to delivery again so that proper updated shipments are created.
    # e.g. customer goes back from payment step and changes order items
    def ensure_updated_shipments
      if shipments.any? && !completed?
        shipments.destroy_all
        update_column(:shipment_total, 0)
        restart_checkout_flow
      end
    end

    def restart_checkout_flow
      update_columns(
        state: 'cart',
        updated_at: Time.current
      )
      next! unless line_items.empty?
    end

    def refresh_shipment_rates(shipping_method_filter = ShippingMethod::DISPLAY_ON_FRONT_END)
      shipments.map { |s| s.refresh_rates(shipping_method_filter) }
    end

    def shipping_eq_billing_address?
      (bill_address.empty? && ship_address.empty?) || bill_address.same_as?(ship_address)
    end

    def set_shipments_cost
      shipments.each(&:update_amounts)
      updater.update_shipment_total
      persist_totals
    end

    def is_risky?
      !payments.risky.empty?
    end

    def canceled_by(user)
      transaction do
        cancel!
        update_columns(
          canceler_id: user.id,
          canceled_at: Time.current
        )
      end
    end

    def approved_by(user)
      transaction do
        approve!
        update_columns(
          approver_id: user.id,
          approved_at: Time.current
        )
      end
    end

    def approved?
      !!approved_at
    end

    def can_approve?
      !approved?
    end

    def consider_risk
      considered_risky! if is_risky? && !approved?
    end

    def considered_risky!
      update_column(:considered_risky, true)
    end

    def approve!
      update_column(:considered_risky, false)
    end

    def reload(options = nil)
      remove_instance_variable(:@tax_zone) if defined?(@tax_zone)
      super
    end

    def tax_total
      included_tax_total + additional_tax_total
    end

    def quantity
      line_items.sum(:quantity)
    end

    def has_non_reimbursement_related_refunds?
      refunds.non_reimbursement.exists? ||
        payments.offset_payment.exists? # how old versions of spree stored refunds
    end

    def collect_backend_payment_methods
      PaymentMethod.available_on_back_end.select { |pm| pm.available_for_order?(self) }
    end

    # determines whether the inventory is fully discounted
    #
    # Returns
    # - true if inventory amount is the exact negative of inventory related adjustments
    # - false otherwise
    def fully_discounted?
      adjustment_total + line_items.map(&:final_amount).sum == 0.0
    end
    alias fully_discounted fully_discounted?

    def promo_code
      promotions.pluck(:code).compact.first
    end

    private

    def link_by_email
      self.email = user.email if user
    end

    # Determine if email is required (we don't want validation errors before we hit the checkout)
    def require_email
      true unless new_record? || ['cart', 'address'].include?(state)
    end

    def ensure_line_items_present
      unless line_items.present?
        errors.add(:base, Spree.t(:there_are_no_items_for_this_order)) && (return false)
      end
    end

    def ensure_available_shipping_rates
      if shipments.empty? || shipments.any? { |shipment| shipment.shipping_rates.blank? }
        # After this point, order redirects back to 'address' state and asks user to pick a proper address
        # Therefore, shipments are not necessary at this point.
        shipments.destroy_all
        errors.add(:base, Spree.t(:items_cannot_be_shipped)) && (return false)
      end
    end

    def after_cancel
      shipments.each(&:cancel!)
      payments.completed.each(&:cancel!)

      # Free up authorized store credits
      payments.store_credits.pending.each(&:void!)

      send_cancel_email
      update_with_updater!
    end

    def send_cancel_email
      OrderMailer.cancel_email(id).deliver_later
    end

    def after_resume
      shipments.each(&:resume!)
      consider_risk
    end

    def use_billing?
      use_billing.in?([true, 'true', '1'])
    end

    def set_currency
      self.currency = Spree::Config[:currency] if self[:currency].nil?
    end

    def create_token
      self.guest_token ||= generate_guest_token
    end

    def collect_payment_methods
      PaymentMethod.available_on_front_end.select { |pm| pm.available_for_order?(self) }
    end

    def credit_card_nil_payment?(attributes)
      payments.store_credits.present? && attributes[:amount].to_f.zero?
    end
  end
end
