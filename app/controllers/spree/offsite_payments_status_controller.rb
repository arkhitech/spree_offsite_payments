#encoding: utf-8
#require 'services/offsite_payments'
module Spree
  class OffsitePaymentsStatusController < ApplicationController
    layout "spree/layouts/spree_offsite_payment"
    before_action :load_processor, except: :status_update
    skip_before_action :verify_authenticity_token, only: [:notification, :return]

    rescue_from OffsitePayments::InvalidRequestError,
                 OffsitePayments::UnVerifiableNotifyError,
                 OffsitePayments::InvalidOutTradeNoError,
                 OffsitePayments::PaymentNotFoundError do |error|
      logger.warn(error.message)
      redirect_to spree.root_path
    end

    def return 
      @result = @processor.process
      #logger.debug("session contains: #{session.inspect}")
      @order = @processor.order
      @payment = Payment.find_by_id(params[:identifier]) if params[:identifier]
      @order||= @payment.order if @payment
      logger.debug("received result of #{@result.to_s} for payment #{@payment.id} of order #{@order.number}")
     
      case @result
      when :payment_processed_already
        # if it's less than a minute ago, maybe it's processed by the "notification"
        flash[:notice] = "Payment Processed Already" if ((Time.now - @processor.payment.updated_at) > 1.minute)
        redirect_to_with_fallback(spree.order_path(@order))
      when :order_completed
        flash[:notice] = "Order Completed"
        #session[:order_id] = nil
        
        redirect_to_with_fallback(spree.order_path(@order))
      when :payment_success_but_order_incomplete
        flash[:warn] = "Payment success but order incomplete"
        #redirect_to edit_order_checkout_url(@order, state: "payment")
        redirect_to_with_fallback(shop_checkout_state_url(shop_id: @order.shop.id, state: "payment"))
      when :payment_failure
        unless @processor.response.errors.blank?
          flash[:error] = @processor.response.errors.join("<br/>").html_safe
        else
          flash[:error] = "Payment failed"
        end
        #redirect_to edit_order_checkout_url(@order, state: "payment")
        redirect_to_with_fallback(shop_checkout_state_url(shop_id: @order.shop.id, state: "payment"))
      else
        redirect_to_with_fallback spree.order_path(@order)
      end
    end

    def redirect_to_with_fallback(order_path)
      if params[:caller] != 'mobile'        
        if params[:caller].present?
          redirect_url_caller = URI.unescape(@return_caller)
          redirect_to redirect_url_caller
        else
          redirect_to order_path
        end
      end
    end
    private :redirect_to_with_fallback
    
    def notification
      result = @processor.process
      logger.debug("content_type::::::#{request.content_type}")
      case result
      when Symbol 
        render text: 'success'
      else
        logger.error "Unexpected result #{result} of type #{result.class}: #{@processor.order.number}"
        render text: 'success'
      end
    end

    def publish_internal_update(payment)
      $redis||=Redis.new
      $redis.publish('payment.update', "payment_paid:#{payment.id}")
    end

    include ActionController::Live
    def status_update
      response.headers['Content-Type'] = 'text/event-stream'
      redis = Redis.new
      redis.subscribe('payment.update', 'heartbeat') do |pu|
        pu.message do |channel, message|
          case channel
          when 'heartbeat'
            response.stream.write("event: heart_beat\n")
            response.stream.write("data: #{message}\n\n")
          when 'payment.update'
            payment_id = message.match(/payment_paid:(.*)/)[1]
            logger.debug("payment update received for #{payment_id}")
            if payment_id == request.params['payment_id']
              logger.debug("sending update to client for payment")
              response.stream.write("event: order_paid\n")
              response.stream.write("data: #{payment_id}\n\n")
            else 
              logger.debug("payment update received for #{payment_id}")
            end
          end
        end
      end
      render nothing: true
    rescue IOError
      logger.warn("Client connection closed")
    ensure
      redis.quit
      response.stream.close
    end

    private

    def load_processor
      if request.params[:caller].present?
        @return_caller = URI.unescape(request.params[:caller])
      end
      if request.params[:method] == 'easy_paisa' && request.params[:auth_token]
        @payment = Payment.find_by_id(request.params[:identifier])
        @auth_code = request.params[:auth_token]
        @caller = request.params[:caller]
        render :easy_paisa_confirm
      else
        @processor = OffsitePayments.load_for(request)
        @processor.log = logger
      end
    end
  end
end
