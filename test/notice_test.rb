require File.join(File.dirname(__FILE__), 'test_helper')

class NoticeTest < Test::Unit::TestCase
  context "A notice" do
    setup do
    end

    context "when initialized with a Hash" do
      setup do
        @hash = {
          :error_class => "RuntimeError",
          :error_message => "This is an error message",
          :backtrace => "one\n  two\nthree  \n  four\n"
        }
        @notice = HoptoadNotifier::Notice.new(@hash)
      end

      should "have the api_key we expect" do
        assert_equal TEST_API_KEY, @notice.api_key
      end 

      should "have the error_message we expect" do
        assert_equal "RuntimeError: This is an error message", @notice.error_message
      end 

      should "have the error_class we expect" do
        assert_equal "RuntimeError", @notice.error_class
      end 

      should "have the backtrace we expect" do
        assert_equal ["one", "two", "three", "four"], @notice.backtrace
      end 

      should "have the request we expect" do
        assert_equal(HoptoadNotifier::Notice::Request.new, @notice.request)
      end 

      should "have the session we expect" do
        assert_equal(HoptoadNotifier::Notice::Session.new, @notice.session)
      end 

      should "have the environment we expect" do
        assert_equal ENV.to_hash, @notice.environment
      end 

      context "converted to YAML" do
        setup do
          @yaml = @notice.to_yaml
          @hash = YAML.load(@yaml)
        end

        should "parse back into a Hash" do
          assert @hash.is_a?(Hash)
        end

        should "have a 'notice' key" do
          assert @hash['notice'].is_a?(Hash)
        end

        %w( environment request session ).each do |key|
          should "contain a #{key} key that contains a hash" do
            assert @hash["notice"][key].is_a?(Hash)
          end
        end

        should "have the right error class" do
          assert_equal "RuntimeError", @hash["notice"]["error_class"]
        end

        should "have the right error message" do
          assert_equal "RuntimeError: This is an error message", @hash["notice"]["error_message"]
        end

        should "have the right api_key" do
          assert_equal TEST_API_KEY, @hash["notice"]["api_key"]
        end

      end
    end

    context "when initialized with an Exception" do
      setup do
        @exception = begin
                       raise "This is an error message"
                     rescue => e
                       e
                     end
        @filters = HoptoadNotifier.backtrace_filters
        HoptoadNotifier.backtrace_filters.clear
        @notice = HoptoadNotifier::Notice.new(@exception)
      end

      teardown do
        HoptoadNotifier.backtrace_filters.concat @filters
      end

      should "have the api_key we expect" do
        assert_equal TEST_API_KEY, @notice.api_key
      end 

      should "have the error_message we expect" do
        assert_equal "RuntimeError: This is an error message", @notice.error_message
      end 

      should "have the error_class we expect" do
        assert_equal "RuntimeError", @notice.error_class
      end 

      should "have the backtrace we expect" do
        assert_equal @exception.backtrace, @notice.backtrace
      end 

      should "have the request we expect" do
        assert_equal(HoptoadNotifier::Notice::Request.new, @notice.request)
      end 

      should "have the session we expect" do
        assert_equal(HoptoadNotifier::Notice::Session.new, @notice.session)
      end 

      should "have the environment we expect" do
        assert_equal ENV.to_hash, @notice.environment
      end 
    end

    context "when backtrace filters are defined" do
      setup do
        HoptoadNotifier.filter_backtrace do |line|
          line.gsub(/FOO/, "BAR")
        end
        @notice = HoptoadNotifier::Notice.new(:backtrace => "FOO\nBAZ\nwhatFOO\nawesome\n")
      end

      should "modify all backtrace lines that match the filter" do
        expected = %w(BAR BAZ whatBAR awesome)
        assert_equal expected, @notice.backtrace
      end
    end

    context "when parameter filters are defined" do
      setup do
        HoptoadNotifier.params_filters << "credit_card"
        @notice = HoptoadNotifier::Notice.new(:request => {
          :params => {"password" => "12345", :credit_card => "12345", "non_sensitive" => "Whee!" }
        })
      end

      should "filter out the parameters and leave others alone" do
        assert_equal "<filtered>", @notice.request.params['password']
        assert_equal "<filtered>", @notice.request.params[:credit_card]
        assert_equal "Whee!",      @notice.request.params["non_sensitive"]
      end
    end

    context "when environment filters are defined" do
      setup do
        HoptoadNotifier.environment_filters << "credit_card"
        @notice = HoptoadNotifier::Notice.new(:environment => {
          "password" => "12345", :credit_card => "12345", "non_sensitive" => "Whee!"
        })
      end

      should "filter out the parameters and leave others alone" do
        assert_equal "12345",      @notice.environment['password']
        assert_equal "<filtered>", @notice.environment[:credit_card]
        assert_equal "Whee!",      @notice.environment["non_sensitive"]
      end
    end
  end
end

