require 'linkeddata'
require 'active_model'
require 'active_support/core_ext/module/delegation'

module LinkedVocabs
  ##
  # Adds add support for controlled vocabularies and
  # QuestioningAuthority to RdfResource classes.
  # @TODO: introduce graph context for provenance
  module Controlled

    def self.included(klass)
      klass.extend ClassMethods
      klass.property :hiddenLabel, :predicate => RDF::Vocab::SKOS.hiddenLabel
      klass.validates_with LinkedVocabs::Validators::AuthorityValidator
    end

    def qa_interface
      self.class.qa_interface
    end
    delegate :search, :get_full_record, :response, :results, :to => :qa_interface

    # Override set_subject! to find terms when (and only when) they
    # exist in the vocabulary
    def set_subject!(uri_or_str)
      vocab_matches = []
      begin
        uri = get_uri(uri_or_str)
        uri_or_str = uri
      rescue RuntimeError, NoMethodError
      end

      return false if uri_or_str.is_a? RDF::Node

      self.class.vocabularies.each do |vocab, config|
        if uri_or_str.start_with? config[:prefix]
          # @TODO: is it good to need a full URI for a non-strict vocab?
          return super if config[:strict] == false
          uri_stub = uri_or_str.to_s.gsub(config[:prefix], '')
          return super(config[:class].send(uri_stub)) if config[:class].respond_to? uri_stub
        else
          # this only matches if the term is explictly defined
          # @TODO: what about the possibility of terms like "entries" or
          # "map" which are methods but not defined properties?  does
          # this need to be patched in RDF::Vocabulary or am I missing
          # something?
          vocab_matches << config[:class].send(uri_or_str) if config[:class].respond_to? uri_or_str
        end
      end
      return super if vocab_matches.empty?
      uri_or_str = vocab_matches.first
      return super if self.class.uses_vocab_prefix?(uri_or_str) and not uri_or_str.kind_of? RDF::Node
    end

    def in_vocab?
      vocab, config = self.class.matching_vocab(rdf_subject.to_s)
      return false unless vocab
      return false if rdf_subject == config[:prefix]
      return false if config[:class].strict? and not config[:class].respond_to? rdf_subject.to_s.gsub(config[:prefix], '').to_sym
      true
    end

    def rdf_label
      labels = Array(self.class.rdf_label) + default_labels
      labels.each do |label|
        values = label_with_preferred_language(label) if values.blank?
        return values unless values.empty?
      end
      node? ? [] : [rdf_subject.to_s]
    end

    def label_with_preferred_language(label)
      values = get_values(label, :literal => true)
      preferred_languages.each do |preferred_language|
        result = filter_by_language(values, preferred_language)
        return result.map(&:to_s) unless result.blank?
      end
      values.map(&:to_s)
    end

    def filter_by_language(values, language)
      values.select { |x| x.language == language}
    end

    def preferred_languages
      [:en, :"en-us"]
    end

    ##
    #  Class methods for adding and using controlled vocabularies
    module ClassMethods
      def use_vocabulary(name, opts={})
        raise ControlledVocabularyError, "Vocabulary undefined: #{name.to_s.upcase}" unless LinkedVocabs.vocabularies.include? name
        opts[:class] = name_to_class(name) unless opts.include? :class
        opts.merge! LinkedVocabs.vocabularies[name.to_sym]
        vocabularies[name] = opts
      end

      def vocabularies
        @vocabularies ||= {}.with_indifferent_access
      end

      ##
      # @return [Array<RDF::URI>] terms allowable by the registered StrictVocabularies
      #
      # Note: this does not necessarily list *all the term* allowable
      # by the class. Non-strict RDF::Vocabularies are not included in
      # this method's output.
      def list_terms
        terms = []
        vocabularies.each do |vocab, config|
          next unless config[:class].respond_to? :properties
          terms += config[:class].properties.select { |s| s.start_with? config[:class].to_s }
        end
        terms
      end

      ##
      # Gets data for all vocabularies used and loads it into the
      # configured repository. After running this new (and reloaded)
      # RdfResource objects of this class will have data from their
      # source web document.
      def load_vocabularies
        vocabularies.each do |name, config|
          load_vocab(name)
        end
      end

      def uses_vocab_prefix?(str)
        !!matching_vocab(str)
      end

      def matching_vocab(str)
        vocabularies.find do |vocab, config|
          str.start_with? config[:prefix]
        end
      end

      def qa_interface
        @qa_interface ||= QaRDF.new(self)
      end

      private

      def name_to_class(name)
        "RDF::#{name.upcase.to_s}".constantize
      end

      def load_vocab(name)
        return nil unless LinkedVocabs.vocabularies[name.to_sym].include? :source
        cache = ActiveTriples::Repositories.repositories[repository]
        graph = RDF::Graph.new(:data => cache, :context => LinkedVocabs.vocabularies[name.to_sym][:source])
        graph.load(LinkedVocabs.vocabularies[name.to_sym][:source])
        graph
      end

      ##
      # Implement QuestioningAuthority API
      class QaRDF
        attr_accessor :response, :raw_response

        def initialize(parent=nil)
          @parent = parent
        end

        ##
        # Not a very smart sparql search. It's mostly intended to be
        # overridden in subclasses, but it could also stand to be a bit
        # better as a baseline RDF vocab search.
        def search(q, sub_authority=nil)
          @sparql = SPARQL::Client.new(ActiveTriples::Repositories.repositories[@parent.repository])
          self.response = sparql_starts_search(q)
          return response unless response.empty?
          self.response = sparql_contains_search(q)
        end

        def results
          response
        end

        def get_full_record(id, sub_authority)
        end

        private

          def sparql_starts_search(q)
            query = @sparql.query("SELECT DISTINCT ?s ?p ?o WHERE { ?s ?p ?o. FILTER(strstarts(lcase(?o), '#{q.downcase}'))}")
            solutions_from_sparql_query(query)
          end

          def sparql_contains_search(q)
            query = @sparql.query("SELECT DISTINCT ?s ?p ?o WHERE { ?s ?p ?o. FILTER(contains(lcase(?o), '#{q.downcase}'))}")
            solutions_from_sparql_query(query)
          end

          def solutions_from_sparql_query(query)
            # @TODO: labels should be taken from ActiveTriples::Resource.
            # However, the default labels there are hidden behind a private method.
            labels = [RDF::SKOS.prefLabel,
                      RDF::DC.title,
                      RDF::RDFS.label]
            labels << @parent.rdf_label unless @parent.rdf_label.nil?

            solutions = query.map { |solution| solution if @parent.uses_vocab_prefix? solution[:s] }.compact
            label_solutions = solutions.map { |solution| build_hit(solution) if labels.include? solution[:p] }.compact
            return label_solutions.uniq unless label_solutions.empty?
            solutions.map { |solution| build_hit(solution) }.compact.uniq
          end

          def build_hit(solution)
            { :id => solution[:s].to_s, :label => solution[:o].to_s }
          end
      end
    end

    class ControlledVocabularyError < StandardError; end
  end
end
