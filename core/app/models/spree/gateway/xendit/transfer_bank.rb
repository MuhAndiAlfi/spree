module Spree
  class Gateway::Xendit::TransferBank < Gateway
    TEST_VISA = ['4111111111111111', '4012888888881881', '4222222222222']
    TEST_MC   = ['5500000000000004', '5555555555554444', '5105105105105100', '2223000010309703']
    TEST_AMEX = ['378282246310005', '371449635398431', '378734493671000', '340000000000009']
    TEST_DISC = ['6011000000000004', '6011111111111117', '6011000990139424']

    VALID_CCS = ['1', TEST_VISA, TEST_MC, TEST_AMEX, TEST_DISC].flatten

    attr_accessor :test

    def provider_class
      self.class
    end

    def preferences
      {}
    end

    def create_profile(payment)
      return if payment.source.has_payment_profile?
      # simulate the storage of credit card profile using remote service
      if success = VALID_CCS.include?(payment.source.number)
        payment.source.update_attributes(gateway_customer_profile_id: generate_profile_id(success))
      end
    end

    def authorize(_money, credit_card, _options = {})
      number = _options[:order_id]
      puts _options.inspect
      # profile_id = credit_card.gateway_customer_profile_id
      # if VALID_CCS.include?(credit_card.number) || (profile_id && profile_id.starts_with?('BGS-'))

      number = _options[:order_id]
      orders = Spree::Order.find_by!(number: number.to_s.split('-').first)
      
      if orders.has_promo? 
        price = orders.display_total_after_discount + orders.shipment_total.to_i 
      else 
        price = orders.total 
      end 

      res = XenditService.new.create_invoice(external_id: _options[:order_id], payer_email: 'test@example.com', description: _options[:order_id], amount: price )
      # binding.pry
      res["available_banks"].each do |available_bank|
        credit_card.virtual_accounts.create(bank_code: available_bank['bank_code'], collection_type: available_bank['collection_type'], bank_account_number: available_bank['bank_account_number'], transfer_amount: available_bank['transfer_amount'], bank_branch: available_bank['bank_branch'], account_holder_name: available_bank['account_holder_name'], identity_amount: available_bank['identity_amount'])
      end

        ActiveMerchant::Billing::Response.new(true, 'Bogus Gateway: Forced success', {}, test: true, authorization: '12345', avs_result: { code: 'D' })
      # else
      #   ActiveMerchant::Billing::Response.new(false, 'Bogus Gateway: Forced failure', { message: 'Bogus Gateway: Forced failure' }, test: true)
      # end
    end

    def purchase(_money, virtual_account, _options = {})
      puts 'purchase'
      # profile_id = credit_card.gateway_customer_profile_id
      # if VALID_CCS.include?(credit_card.number) || (profile_id && profile_id.starts_with?('BGS-'))
      
      number = _options[:order_id]
      orders = Spree::Order.find_by!(number: number.to_s.split('-').first)
      
      if orders.has_promo? 
       puts price = orders.display_total_after_discount + orders.shipment_total.to_i 
      else 
       puts price = orders.total 
      end 


      res = create_invoice(external_id: _options[:order_id], payer_email: _options[:email], description: _options[:order_id], amount: price )
      puts res.inspect

      # create_invoice(external_id: ,money: ,)
        ActiveMerchant::Billing::Response.new(true, 'Bogus Gateway: Forced success', {}, test: true, authorization: '12345', avs_result: { code: 'M' })
      # else
      #   ActiveMerchant::Billing::Response.new(false, 'Bogus Gateway: Forced failure', message: 'Bogus Gateway: Forced failure', test: true)
      # end
    end

    def credit(_money, _credit_card, _response_code, _options = {})
      ActiveMerchant::Billing::Response.new(true, 'Bogus Gateway: Forced success', {}, test: true, authorization: '12345')
    end

    def capture(_money, authorization, _gateway_options)
      if authorization == '12345'
        ActiveMerchant::Billing::Response.new(true, 'Bogus Gateway: Forced success', {}, test: true)
      else
        ActiveMerchant::Billing::Response.new(false, 'Bogus Gateway: Forced failure', error: 'Bogus Gateway: Forced failure', test: true)
      end
    end

    def void(_response_code, _credit_card, _options = {})
      ActiveMerchant::Billing::Response.new(true, 'Bogus Gateway: Forced success', {}, test: true, authorization: '12345')
    end

    def cancel(_response_code)
      ActiveMerchant::Billing::Response.new(true, 'Bogus Gateway: Forced success', {}, test: true, authorization: '12345')
    end

    def test?
      # Test mode is not really relevant with bogus gateway (no such thing as live server)
      true
    end

    def payment_profiles_supported?
      true
    end

    def actions
      %w(capture void credit)
    end

    private

    def generate_profile_id(success)
      record = true
      prefix = success ? 'BGS' : 'FAIL'
      while record
        random = "#{prefix}-#{Array.new(6) { rand(6) }.join}"
        record = CreditCard.find_by(gateway_customer_profile_id: random)
      end
      random
    end
  end
end