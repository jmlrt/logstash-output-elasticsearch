require_relative "../../../spec/es_spec_helper"

if ESHelper.es_version_satisfies?(">= 5")
  describe "Update actions using painless scripts", :integration => true, :update_tests => 'painless' do
    require "logstash/outputs/elasticsearch"

    def get_es_output( options={} )
      settings = {
        "manage_template" => true,
        "index" => "logstash-update",
        "template_overwrite" => true,
        "hosts" => get_host_port(),
        "action" => "update"
      }
      if ESHelper.es_version_satisfies?('<6')
        settings.merge!({"script_lang" => "painless"})
      end
      LogStash::Outputs::ElasticSearch.new(settings.merge!(options))
    end

    before :each do
      @es = get_client
      # Delete all templates first.
      # Clean ES of data before we start.
      @es.indices.delete_template(:name => "*")
      # This can fail if there are no indexes, ignore failure.
      @es.indices.delete(:index => "*") rescue nil
      @es.index(
        :index => 'logstash-update',
        :type => doc_type,
        :id => "123",
        :body => { :message => 'Test', :counter => 1 }
      )
      @es.indices.refresh
    end

    context "scripted updates" do
      if ESHelper.es_version_satisfies?('<6')
        context 'with file based scripts' do
          it "should increment a counter with event/doc 'count' variable" do
            subject = get_es_output({ 'document_id' => "123", 'script' => 'scripted_update', 'script_type' => 'file' })
            subject.register
            subject.multi_receive([LogStash::Event.new("count" => 2)])
            r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "123", :refresh => true)
            expect(r["_source"]["counter"]).to eq(3)
          end

          it "should increment a counter with event/doc '[data][count]' nested variable" do
            subject = get_es_output({ 'document_id' => "123", 'script' => 'scripted_update_nested', 'script_type' => 'file' })
            subject.register
            subject.multi_receive([LogStash::Event.new("data" => { "count" => 3 })])
            r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "123", :refresh => true)
            expect(r["_source"]["counter"]).to eq(4)
          end
        end
      end

      it "should increment a counter with event/doc 'count' variable with inline script" do
        subject = get_es_output({
          'document_id' => "123",
          'script' => 'ctx._source.counter += params.event.counter',
          'script_type' => 'inline'
        })
        subject.register
        subject.multi_receive([LogStash::Event.new("counter" => 3 )])
        r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "123", :refresh => true)
        expect(r["_source"]["counter"]).to eq(4)
      end

      it "should increment a counter with event/doc 'count' variable with event/doc as upsert and inline script" do
        subject = get_es_output({
          'document_id' => "123",
          'doc_as_upsert' => true,
          'script' => 'if( ctx._source.containsKey("counter") ){ ctx._source.counter += params.event.counter; } else { ctx._source.counter = params.event.counter; }',
          'script_type' => 'inline'
        })
        subject.register
        subject.multi_receive([LogStash::Event.new("counter" => 3 )])
        r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "123", :refresh => true)
        expect(r["_source"]["counter"]).to eq(4)
      end

      it "should, with new doc, set a counter with event/doc 'count' variable with event/doc as upsert and inline script" do
        subject = get_es_output({
          'document_id' => "456",
          'doc_as_upsert' => true,
          'script' => 'if( ctx._source.containsKey("counter") ){ ctx._source.counter += params.event.counter; } else { ctx._source.counter = params.event.counter; }',
          'script_type' => 'inline'
        })
        subject.register
        subject.multi_receive([LogStash::Event.new("counter" => 3 )])
        r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "456", :refresh => true)
        expect(r["_source"]["counter"]).to eq(3)
      end

      context 'with an indexed script' do
        it "should increment a counter with event/doc 'count' variable with indexed script" do
          if ESHelper.es_version_satisfies?('<6')
            @es.perform_request(:put, "_scripts/painless/indexed_update", {}, {"script" => "ctx._source.counter += params.event.count" })
          else
            @es.perform_request(:put, "_scripts/indexed_update", {}, {"script" => {"source" => "ctx._source.counter += params.event.count", "lang" => "painless"}})
          end

          plugin_parameters = {
            'document_id' => "123",
            'script' => 'indexed_update',
            'script_type' => 'indexed'
          }

          if ESHelper.es_version_satisfies?('>= 6.0.0')
            plugin_parameters.merge!('script_lang' => '')
          end

          subject = get_es_output(plugin_parameters)
          subject.register
          subject.multi_receive([LogStash::Event.new("count" => 4 )])
          r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "123", :refresh => true)
          expect(r["_source"]["counter"]).to eq(5)
        end
      end
     end

    context "when update with upsert" do
      it "should create new documents with provided upsert" do
        subject = get_es_output({ 'document_id' => "456", 'upsert' => '{"message": "upsert message"}' })
        subject.register
        subject.multi_receive([LogStash::Event.new("message" => "sample message here")])
        r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "456", :refresh => true)
        expect(r["_source"]["message"]).to eq('upsert message')
      end

      it "should create new documents with event/doc as upsert" do
        subject = get_es_output({ 'document_id' => "456", 'doc_as_upsert' => true })
        subject.register
        subject.multi_receive([LogStash::Event.new("message" => "sample message here")])
        r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "456", :refresh => true)
        expect(r["_source"]["message"]).to eq('sample message here')
      end

      it "should fail on documents with event/doc as upsert at external version" do
        subject = get_es_output({ 'document_id' => "456", 'doc_as_upsert' => true, 'version' => 999, "version_type" => "external" })
        expect { subject.register }.to raise_error(LogStash::ConfigurationError)
      end
    end

    context "updates with scripted upsert" do
      if ESHelper.es_version_satisfies?('<6')
        context 'with file based scripts' do
          it "should create new documents with upsert content" do
            subject = get_es_output({ 'document_id' => "456", 'script' => 'scripted_update', 'upsert' => '{"message": "upsert message"}', 'script_type' => 'file' })
            subject.register
            subject.multi_receive([LogStash::Event.new("message" => "sample message here")])
            r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "456", :refresh => true)
            expect(r["_source"]["message"]).to eq('upsert message')
          end

          it "should create new documents with event/doc as script params" do
            subject = get_es_output({ 'document_id' => "456", 'script' => 'scripted_upsert', 'scripted_upsert' => true, 'script_type' => 'file' })
            subject.register
            subject.multi_receive([LogStash::Event.new("counter" => 1)])
            @es.indices.refresh
            r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "456", :refresh => true)
            expect(r["_source"]["counter"]).to eq(1)
          end
        end
      end

      context 'with an inline script' do
        it "should create new documents with upsert content" do
          subject = get_es_output({ 'document_id' => "456", 'script' => 'ctx._source.counter = params.event.counter', 'upsert' => '{"message": "upsert message"}', 'script_type' => 'inline' })
          subject.register

          subject.multi_receive([LogStash::Event.new("message" => "sample message here")])
          r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "456", :refresh => true)
          expect(r["_source"]["message"]).to eq('upsert message')
        end

        it "should create new documents with event/doc as script params" do
          subject = get_es_output({ 'document_id' => "456", 'script' => 'ctx._source.counter = params.event.counter', 'scripted_upsert' => true, 'script_type' => 'inline' })
          subject.register
          subject.multi_receive([LogStash::Event.new("counter" => 1)])
          @es.indices.refresh
          r = @es.get(:index => 'logstash-update', :type => doc_type, :id => "456", :refresh => true)
          expect(r["_source"]["counter"]).to eq(1)
        end
      end
    end
  end
end
