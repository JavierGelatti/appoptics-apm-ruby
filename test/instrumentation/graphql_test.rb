# frozen_string_literal: true

#--
# Copyright (c) 2019 SolarWinds, LLC.
# All rights reserved.
#++

require 'minitest_helper'
require 'mocha/minitest'

if Gem.loaded_specs['graphql'].version >= Gem::Version.new('1.8.0')

  describe GraphQL::Tracing::AppOpticsTracing do
    module Mutations
      class BaseMutation < GraphQL::Schema::Mutation
        #   null false
      end

      class CreateCompany < Mutations::BaseMutation
        argument :name, String, required: true
        argument :id, Integer, required: true

        field :name, String, null: true
        field :id, Integer, null: false

        def resolve(name:, id:)
          OpenStruct.new(
            id: id,
            name: name
          )
        end
      end
    end

    module Types
      class BaseArgument < GraphQL::Schema::Argument
      end

      class BaseField < GraphQL::Schema::Field
        argument_class Types::BaseArgument
      end

      class BaseObject < GraphQL::Schema::Object
        field_class Types::BaseField
      end

      class MyMutation < GraphQL::Schema::Object
        field :create_company, mutation: Mutations::CreateCompany
      end
    end

    module AppOpticsTest
      class Schema < GraphQL::Schema
        def self.id_from_object(_object = nil, _type = nil, _context = {})
          SecureRandom.uuid
        end

        class Address < GraphQL::Schema::Object
          global_id_field :id
          field :street, String, null: true
          field :number, Integer, null: true
          field :more, Integer, null: true
        end

        class Person < GraphQL::Schema::Object
          global_id_field :id
          field :name, String, null: true
          field :nickname, Integer, null: false
          field :othername, String, null: true do
            argument :upcase, String, required: false
          end

          def other_name(upcase = false)
            return 'WHO AM I???' if upcase

            'who am i?'
          end
        end

        class Company < GraphQL::Schema::Object
          global_id_field :id
          field :name, String, null: true
          field :address, Schema::Address, null: true
          field :founder, Schema::Person, null: true
          field :owner, Schema::Person, null: true

          def address
            OpenStruct.new(
              id: AppOpticsTest::Schema.id_from_object,
              street: 'MyStreetName',
              number: Random.new.rand(555),
              more: nil
            )
          end

          def founder
            OpenStruct.new(
              id: AppOpticsTest::Schema.id_from_object,
              name: 'Peter Pan',
              nickname: nil
            )
          end

          def owner
            OpenStruct.new(
              id: AppOpticsTest::Schema.id_from_object,
              name: { a: 1 }
            )
          end
        end
        # rubocop:disable Style/SingleLineMethods
        class MyQuery < GraphQL::Schema::Object
          field :int, Integer, null: false
          def int; 1; end

          field :company, Company, null: true do
            argument :id, ID, required: true
          end

          def company(id:)
            OpenStruct.new(
              id: id,
              name: 'MyName'
            )
          end
        end
        # rubocop:enable Style/SingleLineMethods

        query MyQuery
        mutation Types::MyMutation

        # the following is not necessary because we auto-instrument,
        # it should not create any problems nor a double instrumentation
        # graphql_1_7_4_test tests auto-instrumenting without #use for all versions
        use GraphQL::Tracing::AppOpticsTracing
      end
    end

    # Tests for the graphql gem instrumentation
    before do
      clear_all_traces

      @sanitize_query = AppOpticsAPM::Config[:graphql][:sanitize_query]
      @remove_comments = AppOpticsAPM::Config[:graphql][:remove_comments]
      @enabled = AppOpticsAPM::Config[:graphql][:enabled]
      @transaction_name = AppOpticsAPM::Config[:graphql][:transaction_name]
    end

    after do
      AppOpticsAPM::Config[:graphql][:sanitize_query] = @sanitize_query
      AppOpticsAPM::Config[:graphql][:remove_comments] = @remove_comments
      AppOpticsAPM::Config[:graphql][:enabled] = @enabled
      AppOpticsAPM::Config[:graphql][:transaction_name] = @transaction_name
    end

    it 'traces a simple graphql request' do
      AppOpticsAPM::SDK.start_trace('graphql_test') do
        query = 'query MyInt { int }'
        AppOpticsTest::Schema.execute(query)
      end

      traces = get_all_traces

      # this also checks the presence of X-Trace
      assert valid_edges?(traces, true), 'failed: edges not valid'

      keys = GraphQL::Tracing::AppOpticsTracing::PREP_KEYS.dup
      traces.each do |tr|
        if tr[:Layer] == 'graphql.prep' && tr[:Label] == 'entry'
          assert tr[:Key], 'failure: no :Key in the KVs in the graphql.prep span'
          keys = keys.delete(tr[:Key])
        end
      end
      # The following applies that all the prep events are used
      # (This may not always be true, it is also not that important, but lets test
      # it so we get alerted when something changes)
      assert_empty keys

      tr_01 = traces[1]
      assert_equal "graphql.prep", tr_01[:Layer]
      assert_equal "entry", tr_01[:Label]
      assert_equal "graphql", tr_01[:Spec]
      assert_equal "query MyInt { int }", tr_01[:InboundQuery], "failure: InboundQuery not matching"

      assert_equal "graphql.query.MyInt", traces.last[:TransactionName], "failure: TransactionName not matching"
    end

    # rubocop:disable Lint/AmbiguousBlockAssociation
    it 'traces a more complex graphql request' do
      query = <<-GRAPHQL
        query MyCompany { company(id: "abc") {
          founder {
            name
          }
          owner {
            name
          }
        }}
      GRAPHQL

      AppOpticsAPM::SDK.start_trace('graphql_test') do
        AppOpticsTest::Schema.execute(query)
      end

      traces = get_all_traces
      assert valid_edges?(traces, true), 'failed: edges not valid'

      assert traces.find { |tr| tr[:InboundQuery] == query.gsub(/abc/, '?') }
      assert traces.find { |tr| tr[:Layer] == 'graphql.MyQuery.company' && tr[:Label] == 'entry' }
      assert traces.find { |tr| tr[:Layer] == 'graphql.MyQuery.company' && tr[:Label] == 'exit' }
      assert traces.find { |tr| tr[:Layer] == 'graphql.Company.founder' && tr[:Label] == 'entry' }
      assert traces.find { |tr| tr[:Layer] == 'graphql.Company.founder' && tr[:Label] == 'exit' }
      assert traces.find { |tr| tr[:Layer] == 'graphql.Company.owner' && tr[:Label] == 'entry' }
      assert traces.find { |tr| tr[:Layer] == 'graphql.Company.owner' && tr[:Label] == 'exit' }
    end

    it 'traces a mutation' do
      query = <<-GRAPHQL
      mutation { createCompany (id: 7, name: "the best") {
        name
        id
      }}
      GRAPHQL

      AppOpticsAPM::SDK.start_trace('graphql_test') do
        AppOpticsTest::Schema.execute(query)
      end

      traces = get_all_traces
      assert valid_edges?(traces, true), 'failed: edges not valid'

      assert traces.find { |tr| tr[:Layer] == 'graphql.MyMutation.createCompany' && tr[:Label] == 'entry' }
      assert traces.find { |tr| tr[:Layer] == 'graphql.MyMutation.createCompany' && tr[:Label] == 'exit' }
    end
    # rubocop:enable Lint/AmbiguousBlockAssociation

    it 'adds an error event for a disallowed null value' do
      query = <<-GRAPHQL
        query MyNullValue { company(id: "abc") {
          founder {
            nickname
          }
          owner {
            name
          }
        }}
      GRAPHQL

      AppOpticsAPM::SDK.start_trace('graphql_test') do
        AppOpticsTest::Schema.execute(query)
      end

      traces = get_all_traces
      assert valid_edges?(traces, true), 'failed: edges not valid'

      error_tr = traces.find { |tr| tr[:Label] == 'error' && tr[:ErrorMsg] }

      assert error_tr, 'failed: No Error event was logged with the trace'
    end

    describe 'test configs' do
      let(:query) do
        <<-GRAPHQL
        query MyLetQuery { company(id: "abc") {
          founder {
            # I forgot her name
            name
            otherName(upcase: "yes please")
          }
        }}
        GRAPHQL
      end

      it 'replaces query parameters if sanitize_query is TRUE' do
        AppOpticsAPM::Config[:graphql][:sanitize_query] = true

        AppOpticsAPM::SDK.start_trace('graphql_test') do
          AppOpticsTest::Schema.execute(query)

          traces = get_all_traces
          traces.each do |tr|
            if tr[:InboundQuery]
              refute_match 'abc', tr[:InboundQuery]
              refute_match 'yes please', tr[:InboundQuery]
            end
          end
        end
      end

      it 'does not replace query parameters if sanitize_query is FALSE' do
        AppOpticsAPM::Config[:graphql][:sanitize_query] = false

        AppOpticsAPM::SDK.start_trace('graphql_test') do
          AppOpticsTest::Schema.execute(query)

          traces = get_all_traces
          traces.each do |tr|
            if tr[:InboundQuery]
              assert_match 'abc', tr[:InboundQuery]
              assert_match 'yes please', tr[:InboundQuery]
            end
          end
        end
      end

      it 'removes comments if remove_comment is TRUE' do
        AppOpticsAPM::Config[:graphql][:remove_comments] = true

        AppOpticsAPM::SDK.start_trace('graphql_test') do
          AppOpticsTest::Schema.execute(query)

          traces = get_all_traces
          traces.each do |tr|
            refute_match '#', tr[:InboundQuery] if tr[:InboundQuery]
          end
        end
      end

      it 'does not remove comments if remove_comment is FALSE' do
        AppOpticsAPM::Config[:graphql][:remove_comments] = false

        AppOpticsAPM::SDK.start_trace('graphql_test') do
          AppOpticsTest::Schema.execute(query)

          traces = get_all_traces
          traces.each do |tr|
            assert_match '#', tr[:InboundQuery] if tr[:InboundQuery]
          end
        end
      end

      it 'sets a graphql transaction name if transaction_name is TRUE' do
        AppOpticsAPM::Config[:graphql][:transaction_name] = true
        AppOpticsAPM::SDK.start_trace('graphql_test') do
          AppOpticsTest::Schema.execute(query)
        end

        trace = get_all_traces.last
        assert_equal "graphql.query.MyLetQuery", trace[:TransactionName]
      end

      it 'does not set a graphql transaction name if transaction_name is FALSE' do
        AppOpticsAPM::Config[:graphql][:transaction_name] = false
        AppOpticsAPM::SDK.start_trace('graphql_test') do
          AppOpticsTest::Schema.execute(query)
        end

        trace = get_all_traces.last
        assert_equal "custom-graphql_test", trace[:TransactionName]
      end

      it 'sets the type in the transaction name to query if it was omitted' do
        AppOpticsAPM::Config[:graphql][:transaction_name] = true
        query_short = '{company (id: 1) { name}}'
        AppOpticsAPM::SDK.start_trace('graphql_test') do
          AppOpticsTest::Schema.execute(query_short)
        end
        trace = get_all_traces.last
        assert_equal "graphql.query.company", trace[:TransactionName]
      end

      it 'does not create traces if graphql is not enabled' do
        AppOpticsAPM::Config[:graphql][:enabled] = false
        AppOpticsAPM::SDK.start_trace('graphql_test') do
          AppOpticsTest::Schema.execute(query)
        end
        traces = get_all_traces
        assert_equal 2, traces.size, "failed: It should not have created traces for graphql"
      end

      it 'does not trace if there is no context' do
        AppOpticsTest::Schema.execute(query)
        traces = get_all_traces
        assert_empty traces, 'failed: it should not have created any traces'
      end
    end

    describe 'multiplex requests' do
      it 'traces multiplex queries' do
        queries = [
          {
            query: 'query MyFirstCompany { company(id: 1) { name } }',
            variables: {},
            operation_name: 'MyFirstCompany',
            context: {}
          },
          {
            query: 'query MySecondCompany { company(id: 2) { name } }',
            variables: { num: 3 },
            operation_name: 'MySecondCompany',
            context: {}
          },
          {
            query: 'query MyThirdCompany { company(id: 3) { name } }',
            operation_name: 'MyThirdCompany',
            variables: {},
            context: {}
          }
        ]

        AppOpticsAPM::SDK.start_trace('graphql_multi_test') do
          AppOpticsTest::Schema.multiplex(queries)
        end

        traces = get_all_traces

        exec_trace = traces.find { |tr| tr[:Layer] == 'graphql.execute' && tr[:Operations] }
        assert_equal 'MyFirstCompany, MySecondCompany, MyThirdCompany',
                     exec_trace[:Operations]
        assert_equal 'graphql.multiplex.MyFirstCompany.MySecondCompany.MyThirdCompany',
                     traces.last[:TransactionName]
      end

      it 'truncates long transaction names' do
        queries = [
          {
            query: 'query MyFirstCompanyMyFirstCompanyMyFirstCompanyMyFirstCompany { company(id: 1) { name } }',
            variables: {},
            operation_name: 'MyFirstCompany',
            context: {}
          },
          {
            query: 'query MySecondCompanyMySecondCompanyMySecondCompanyMySecondCompany { company(id: 2) { name } }',
            variables: { num: 3 },
            operation_name: 'MySecondCompany',
            context: {}
          },
          {
            query: 'query MyThirdCompanyMyThirdCompanyMyThirdCompanyMyThirdCompany { company(id: 3) { name } }',
            operation_name: 'MyThirdCompany',
            variables: {},
            context: {}
          },
          {
            query: 'query MyThirdCompanyMyForthCompanyMyForthCompanyMyForthCompanyMyForthCompany { company(id: 3) { name } }',
            operation_name: 'MyForthCompany',
            variables: {},
            context: {}
          }
        ]

        AppOpticsAPM::SDK.start_trace('graphql_multi_test') do
          AppOpticsTest::Schema.multiplex(queries)
        end

        traces = get_all_traces
        assert_equal 'graphql.multiplex.MyFirstCompanyMyFirstCompanyMyFirstCompanyMyFirstCompany.MySecondCompanyMySecondCompanyMySecondCompanyMySecondCompany.MyThirdCompanyMyThirdCompanyMyThirdCompanyMyThirdCompany.MyThirdCompanyMyForthCompanyMyForthCompanyMyForthCompanyMyF...',
                     traces.last[:TransactionName]
      end
    end

    describe 'loading' do
      # in these 2 tests we are simulating the fact that the
      # GraphQL::Tracing::AppOpticsTracing class
      # from the graphql gem will be loaded first
      it 'uses the newer version of AppOpticsTracing from the appoptics_apm gem' do
          load 'test/instrumentation/graphql/appoptics_tracing_older.rb'
          load 'lib/appoptics_apm/inst/graphql.rb'

          assert_match 'lib/appoptics_apm/inst/graphql.rb',
                       GraphQL::Tracing::AppOpticsTracing.new.method(:metadata).source_location[0]
          assert_match 'lib/appoptics_apm/inst/graphql.rb',
                       GraphQL::Tracing::AppOpticsTracing.new.method(:platform_trace).source_location[0]
      end

      it 'uses the newer version of AppOpticsTracing from the graphql gem' do
          load 'test/instrumentation/graphql/appoptics_tracing_newer.rb'
          load 'lib/appoptics_apm/inst/graphql.rb'

          assert_match 'graphql/appoptics_tracing_newer.rb',
                       GraphQL::Tracing::AppOpticsTracing.new.method(:metadata).source_location[0]
          assert_match 'graphql/appoptics_tracing_newer.rb',
                       GraphQL::Tracing::AppOpticsTracing.new.method(:platform_trace).source_location[0]
      end

      it 'does not add plugins twice' do
        GraphQL::Schema.use(GraphQL::Tracing::AppOpticsTracing)
        GraphQL::Schema.use(GraphQL::Tracing::AppOpticsTracing)

        assert_equal GraphQL::Schema.plugins.uniq.size, GraphQL::Schema.plugins.size,
                     'failed: duplicate plugins found'
      end
    end
  end
end
