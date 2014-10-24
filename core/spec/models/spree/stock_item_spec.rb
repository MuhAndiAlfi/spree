require 'spec_helper'

describe Spree::StockItem, :type => :model do
  let(:stock_location) { create(:stock_location_with_items) }

  subject { stock_location.stock_items.order(:id).first }

  it 'maintains the count on hand for a variant' do
    expect(subject.count_on_hand).to eq 10
  end

  it "can return the stock item's variant's name" do
    expect(subject.variant_name).to eq(subject.variant.name)
  end

  context "available to be included in shipment" do
    context "has stock" do
      it { expect(subject).to be_available }
    end

    context "backorderable" do
      before { subject.backorderable = true }
      it { expect(subject).to be_available }
    end

    context "no stock and not backorderable" do
      before do
        subject.backorderable = false
        allow(subject).to receive_messages(count_on_hand: 0)
      end

      it { expect(subject).not_to be_available }
    end
  end

  describe 'reduce_count_on_hand_to_zero' do
    context 'when count_on_hand > 0' do
      before(:each) do
        subject.update_column('count_on_hand', 4)
         subject.reduce_count_on_hand_to_zero
       end

       it { expect(subject.count_on_hand).to eq(0) }
     end

     context 'when count_on_hand > 0' do
       before(:each) do
         subject.update_column('count_on_hand', -4)
         @count_on_hand = subject.count_on_hand
         subject.reduce_count_on_hand_to_zero
       end

       it { expect(subject.count_on_hand).to eq(@count_on_hand) }
     end
  end

  context "adjust count_on_hand" do
    let!(:current_on_hand) { subject.count_on_hand }

    it 'is updated pessimistically' do
      copy = Spree::StockItem.find(subject.id)

      subject.adjust_count_on_hand(5)
      expect(subject.count_on_hand).to eq(current_on_hand + 5)

      expect(copy.count_on_hand).to eq(current_on_hand)
      copy.adjust_count_on_hand(5)
      expect(copy.count_on_hand).to eq(current_on_hand + 10)
    end

    context "item out of stock (by two items)" do
      let(:inventory_unit) { double('InventoryUnit') }
      let(:inventory_unit_2) { double('InventoryUnit2') }

      before do
        allow(subject).to receive_messages(:backordered_inventory_units => [inventory_unit, inventory_unit_2])
        subject.update_column(:count_on_hand, -2)
      end

      # Regression test for #3755
      it "processes existing backorders, even with negative stock" do
        expect(inventory_unit).to receive(:fill_backorder)
        expect(inventory_unit_2).not_to receive(:fill_backorder)
        subject.adjust_count_on_hand(1)
        expect(subject.count_on_hand).to eq(-1)
      end

      # Test for #3755
      it "does not process backorders when stock is adjusted negatively" do
        expect(inventory_unit).not_to receive(:fill_backorder)
        expect(inventory_unit_2).not_to receive(:fill_backorder)
        subject.adjust_count_on_hand(-1)
        expect(subject.count_on_hand).to eq(-3)
      end

      context "adds new items" do
        before { allow(subject).to receive_messages(:backordered_inventory_units => [inventory_unit, inventory_unit_2]) }

        it "fills existing backorders" do
          expect(inventory_unit).to receive(:fill_backorder)
          expect(inventory_unit_2).to receive(:fill_backorder)

          subject.adjust_count_on_hand(3)
          expect(subject.count_on_hand).to eq(1)
        end
      end
    end
  end

  context "set count_on_hand" do
    let!(:current_on_hand) { subject.count_on_hand }

    it 'is updated pessimistically' do
      copy = Spree::StockItem.find(subject.id)

      subject.set_count_on_hand(5)
      expect(subject.count_on_hand).to eq(5)

      expect(copy.count_on_hand).to eq(current_on_hand)
      copy.set_count_on_hand(10)
      expect(copy.count_on_hand).to eq(current_on_hand)
    end

    context "item out of stock (by two items)" do
      let(:inventory_unit) { double('InventoryUnit') }
      let(:inventory_unit_2) { double('InventoryUnit2') }

      before { subject.set_count_on_hand(-2) }

      it "doesn't process backorders" do
        expect(subject).not_to receive(:backordered_inventory_units)
      end

      context "adds new items" do
        before { allow(subject).to receive_messages(:backordered_inventory_units => [inventory_unit, inventory_unit_2]) }

        it "fills existing backorders" do
          expect(inventory_unit).to receive(:fill_backorder)
          expect(inventory_unit_2).to receive(:fill_backorder)

          subject.set_count_on_hand(1)
          expect(subject.count_on_hand).to eq(1)
        end
      end
    end
  end

  context "with stock movements" do
    before { Spree::StockMovement.create(stock_item: subject, quantity: 1) }

    it "doesnt raise ReadOnlyRecord error" do
      expect { subject.destroy }.not_to raise_error
    end
  end

  context "destroyed" do
    before { subject.destroy }

    it "recreates stock item just fine" do
      expect {
        stock_location.stock_items.create!(variant: subject.variant)
      }.not_to raise_error
    end

    it "doesnt allow recreating more than one stock item at once" do
      stock_location.stock_items.create!(variant: subject.variant)

      expect {
        stock_location.stock_items.create!(variant: subject.variant)
      }.to raise_error
    end
  end

  describe "#after_save" do
    before do
      subject.variant.update_column(:updated_at, 1.day.ago)
    end

    context "binary_inventory_cache is set to false (default)" do
      context "in_stock? changes" do
        it "touches its variant" do
          expect do
            subject.adjust_count_on_hand(subject.count_on_hand * -1)
          end.to change { subject.variant.reload.updated_at }
        end
      end

      context "in_stock? does not change" do
        it "touches its variant" do
          expect do
            subject.adjust_count_on_hand((subject.count_on_hand * -1) + 1)
          end.to change { subject.variant.reload.updated_at }
        end
      end
    end

    context "binary_inventory_cache is set to true" do
      before { Spree::Config.binary_inventory_cache = true }
      context "in_stock? changes" do
        it "touches its variant" do
          expect do
            subject.adjust_count_on_hand(subject.count_on_hand * -1)
          end.to change { subject.variant.reload.updated_at }
        end
      end

      context "in_stock? does not change" do
        it "does not touch its variant" do
          expect do
            subject.adjust_count_on_hand((subject.count_on_hand * -1) + 1)
          end.not_to change { subject.variant.reload.updated_at }
        end
      end

      context "when a new stock location is added" do
        it "touches its variant" do
          expect do
            create(:stock_location)
          end.to change { subject.variant.reload.updated_at }
        end
      end
    end
  end

  describe "#after_touch" do
    it "touches its variant" do
      expect do
        subject.touch
      end.to change { subject.variant.updated_at }
    end
  end

  # Regression test for #4651
  context "variant" do
    it "can be found even if the variant is deleted" do
      subject.variant.destroy
      expect(subject.reload.variant).not_to be_nil
    end
  end

  describe 'validations' do
    describe 'count_on_hand' do
      shared_examples_for 'valid count_on_hand' do
        before(:each) do
          subject.save
        end

        it 'has :no errors_on' do
          expect(subject.errors_on(:count_on_hand).size).to eq(0)
        end
      end

      shared_examples_for 'not valid count_on_hand' do
        before(:each) do
          subject.save
        end

        it 'has 1 error_on' do
          expect(subject.error_on(:count_on_hand).size).to eq(1)
        end
        it { expect(subject.errors[:count_on_hand]).to include 'must be greater than or equal to 0' }
      end

      context 'when count_on_hand not changed' do
        context 'when not backorderable' do
          before(:each) do
            subject.backorderable = false
          end
          it_should_behave_like 'valid count_on_hand'
        end

        context 'when backorderable' do
          before(:each) do
            subject.backorderable = true
          end
          it_should_behave_like 'valid count_on_hand'
        end
      end

      context 'when count_on_hand changed' do
        context 'when backorderable' do
          before(:each) do
            subject.backorderable = true
          end
          context 'when both count_on_hand and count_on_hand_was are positive' do
            context 'when count_on_hand is greater than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, 3)
                subject.send(:count_on_hand=, subject.count_on_hand + 3)
              end
              it_should_behave_like 'valid count_on_hand'
            end

            context 'when count_on_hand is smaller than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, 3)
                subject.send(:count_on_hand=, subject.count_on_hand - 2)
              end

              it_should_behave_like 'valid count_on_hand'
            end
          end

          context 'when both count_on_hand and count_on_hand_was are negative' do
            context 'when count_on_hand is greater than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, -3)
                subject.send(:count_on_hand=, subject.count_on_hand + 2)
              end
              it_should_behave_like 'valid count_on_hand'
            end

            context 'when count_on_hand is smaller than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, 3)
                subject.send(:count_on_hand=, subject.count_on_hand - 3)
              end

              it_should_behave_like 'valid count_on_hand'
            end
          end

          context 'when both count_on_hand is positive and count_on_hand_was is negative' do
            context 'when count_on_hand is greater than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, -3)
                subject.send(:count_on_hand=, subject.count_on_hand + 6)
              end
              it_should_behave_like 'valid count_on_hand'
            end
          end

          context 'when both count_on_hand is negative and count_on_hand_was is positive' do
            context 'when count_on_hand is greater than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, 3)
                subject.send(:count_on_hand=, subject.count_on_hand - 6)
              end
              it_should_behave_like 'valid count_on_hand'
            end
          end
        end

        context 'when not backorderable' do
          before(:each) do
            subject.backorderable = false
          end

          context 'when both count_on_hand and count_on_hand_was are positive' do
            context 'when count_on_hand is greater than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, 3)
                subject.send(:count_on_hand=, subject.count_on_hand + 3)
              end
              it_should_behave_like 'valid count_on_hand'
            end

            context 'when count_on_hand is smaller than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, 3)
                subject.send(:count_on_hand=, subject.count_on_hand - 2)
              end

              it_should_behave_like 'valid count_on_hand'
            end
          end

          context 'when both count_on_hand and count_on_hand_was are negative' do
            context 'when count_on_hand is greater than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, -3)
                subject.send(:count_on_hand=, subject.count_on_hand + 2)
              end
              it_should_behave_like 'valid count_on_hand'
            end

            context 'when count_on_hand is smaller than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, -3)
                subject.send(:count_on_hand=, subject.count_on_hand - 3)
              end

              it_should_behave_like 'not valid count_on_hand'
            end
          end

          context 'when both count_on_hand is positive and count_on_hand_was is negative' do
            context 'when count_on_hand is greater than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, -3)
                subject.send(:count_on_hand=, subject.count_on_hand + 6)
              end
              it_should_behave_like 'valid count_on_hand'
            end
          end

          context 'when both count_on_hand is negative and count_on_hand_was is positive' do
            context 'when count_on_hand is greater than count_on_hand_was' do
              before(:each) do
                subject.update_column(:count_on_hand, 3)
                subject.send(:count_on_hand=, subject.count_on_hand - 6)
              end
              it_should_behave_like 'not valid count_on_hand'
            end
          end
        end
      end
    end
  end
end
