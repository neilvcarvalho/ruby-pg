# -*- ruby -*-
# frozen_string_literal: true

require 'pg' unless defined?( PG )

# This class defines the mapping between PostgreSQL types and encoder/decoder classes for PG::BasicTypeMapForResults, PG::BasicTypeMapForQueries and PG::BasicTypeMapBasedOnResult.
#
# Additional types can be added like so:
#
#   require 'pg'
#   require 'ipaddr'
#
#   class InetDecoder < PG::SimpleDecoder
#     def decode(string, tuple=nil, field=nil)
#       IPAddr.new(string)
#     end
#   end
#   class InetEncoder < PG::SimpleEncoder
#     def encode(ip_addr)
#       ip_addr.to_s
#     end
#   end
#
#   conn = PG.connect
#   regi = PG::BasicTypeRegistry.new.define_default_types
#   regi.register_type(0, 'inet', InetEncoder, InetDecoder)
#   conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn, registry: regi)
class PG::BasicTypeRegistry
	# An instance of this class stores the coders that should be used for a particular wire format (text or binary)
	# and type cast direction (encoder or decoder).
	#
	# Each coder object is filled with the PostgreSQL type name, OID, wire format and array coders are filled with the base elements_type.
	class CoderMap
		# Hash of text types that don't require quotation, when used within composite types.
		#   type.name => true
		DONT_QUOTE_TYPES = %w[
			int2 int4 int8
			float4 float8
			oid
			bool
			date timestamp timestamptz
		].inject({}){|h,e| h[e] = true; h }

		def initialize(result, coders_by_name, format, arraycoder)
			coder_map = {}

			arrays, nodes = result.partition { |row| row['typinput'] == 'array_in' }

			# populate the base types
			nodes.find_all { |row| coders_by_name.key?(row['typname']) }.each do |row|
				coder = coders_by_name[row['typname']].dup
				coder.oid = row['oid'].to_i
				coder.name = row['typname']
				coder.format = format
				coder_map[coder.oid] = coder
			end

			if arraycoder
				# populate array types
				arrays.each do |row|
					elements_coder = coder_map[row['typelem'].to_i]
					next unless elements_coder

					coder = arraycoder.new
					coder.oid = row['oid'].to_i
					coder.name = row['typname']
					coder.format = format
					coder.elements_type = elements_coder
					coder.needs_quotation = !DONT_QUOTE_TYPES[elements_coder.name]
					coder_map[coder.oid] = coder
				end
			end

			@coders = coder_map.values
			@coders_by_name = @coders.inject({}){|h, t| h[t.name] = t; h }
			@coders_by_oid = @coders.inject({}){|h, t| h[t.oid] = t; h }
		end

		attr_reader :coders
		attr_reader :coders_by_oid
		attr_reader :coders_by_name

		def coder_by_name(name)
			@coders_by_name[name]
		end

		def coder_by_oid(oid)
			@coders_by_oid[oid]
		end
	end

	# An instance of this class stores CoderMap instances to be used for text and binary wire formats
	# as well as encoder and decoder directions.
	#
	# A PG::BasicTypeRegistry::CoderMapsBundle instance retrieves all type definitions from the PostgreSQL server and matches them with the coder definitions of the global PG::BasicTypeRegistry .
	# It provides 4 separate CoderMap instances for the combinations of the two formats and directions.
	#
	# A PG::BasicTypeRegistry::CoderMapsBundle instance can be used to initialize an instance of
	# * PG::BasicTypeMapForResults
	# * PG::BasicTypeMapForQueries
	# * PG::BasicTypeMapBasedOnResult
	# by passing it instead of the connection object like so:
	#
	#   conn = PG::Connection.new
	#   maps = PG::BasicTypeRegistry::CoderMapsBundle.new(conn)
	#   conn.type_map_for_results = PG::BasicTypeMapForResults.new(maps)
	#
	class CoderMapsBundle
		attr_reader :typenames_by_oid

		def initialize(connection, registry: nil)
			registry ||= DEFAULT_TYPE_REGISTRY

			result = connection.exec(<<-SQL).to_a
				SELECT t.oid, t.typname, t.typelem, t.typdelim, ti.proname AS typinput
				FROM pg_type as t
				JOIN pg_proc as ti ON ti.oid = t.typinput
			SQL

			@maps = [
				[0, :encoder, PG::TextEncoder::Array],
				[0, :decoder, PG::TextDecoder::Array],
				[1, :encoder, nil],
				[1, :decoder, nil],
			].inject([]) do |h, (format, direction, arraycoder)|
				coders = registry.coders_for(format, direction) || {}
				h[format] ||= {}
				h[format][direction] = CoderMap.new(result, coders, format, arraycoder)
				h
			end

			@typenames_by_oid = result.inject({}){|h, t| h[t['oid'].to_i] = t['typname']; h }
		end

		def each_format(direction)
			@maps.map { |f| f[direction] }
		end

		def map_for(format, direction)
			@maps[format][direction]
		end
	end

	module Checker
		ValidFormats = { 0 => true, 1 => true }
		ValidDirections = { :encoder => true, :decoder => true }

		protected def check_format_and_direction(format, direction)
			raise(ArgumentError, "Invalid format value %p" % format) unless ValidFormats[format]
			raise(ArgumentError, "Invalid direction %p" % direction) unless ValidDirections[direction]
		end

		protected def build_coder_maps(conn_or_maps, registry: nil)
			if conn_or_maps.is_a?(PG::BasicTypeRegistry::CoderMapsBundle)
				raise ArgumentError, "registry argument must be given to CoderMapsBundle" if registry
				conn_or_maps
			else
				PG::BasicTypeRegistry::CoderMapsBundle.new(conn_or_maps, registry: registry)
			end
		end
	end

	include Checker

  def initialize
		# The key of these hashs maps to the `typname` column from the table pg_type.
		@coders_by_name = []
	end

	# Retrieve a Hash of all en- or decoders for a given wire format.
	# The hash key is the name as defined in table +pg_type+.
	# The hash value is the registered coder object.
	def coders_for(format, direction)
		check_format_and_direction(format, direction)
		@coders_by_name[format]&.[](direction)
	end

	# Register an encoder or decoder instance for casting a PostgreSQL type.
	#
	# Coder#name must correspond to the +typname+ column in the +pg_type+ table.
	# Coder#format can be 0 for text format and 1 for binary.
	def register_coder(coder)
		h = @coders_by_name[coder.format] ||= { encoder: {}, decoder: {} }
		name = coder.name || raise(ArgumentError, "name of #{coder.inspect} must be defined")
		h[:encoder][name] = coder if coder.respond_to?(:encode)
		h[:decoder][name] = coder if coder.respond_to?(:decode)
	end

	# Register the given +encoder_class+ and/or +decoder_class+ for casting a PostgreSQL type.
	#
	# +name+ must correspond to the +typname+ column in the +pg_type+ table.
	# +format+ can be 0 for text format and 1 for binary.
	def register_type(format, name, encoder_class, decoder_class)
		register_coder(encoder_class.new(name: name, format: format)) if encoder_class
		register_coder(decoder_class.new(name: name, format: format)) if decoder_class
	end

	# Alias the +old+ type to the +new+ type.
	def alias_type(format, new, old)
		[:encoder, :decoder].each do |ende|
			enc = @coders_by_name[format][ende][old]
			if enc
				@coders_by_name[format][ende][new] = enc
			else
				@coders_by_name[format][ende].delete(new)
			end
		end
	end

	# Populate the registry with all builtin types of ruby-pg
	def define_default_types
		register_type 0, 'int2', PG::TextEncoder::Integer, PG::TextDecoder::Integer
		alias_type    0, 'int4', 'int2'
		alias_type    0, 'int8', 'int2'
		alias_type    0, 'oid',  'int2'

		register_type 0, 'numeric', PG::TextEncoder::Numeric, PG::TextDecoder::Numeric
		register_type 0, 'text', PG::TextEncoder::String, PG::TextDecoder::String
		alias_type 0, 'varchar', 'text'
		alias_type 0, 'char', 'text'
		alias_type 0, 'bpchar', 'text'
		alias_type 0, 'xml', 'text'
		alias_type 0, 'name', 'text'

		# FIXME: why are we keeping these types as strings?
		# alias_type 'tsvector', 'text'
		# alias_type 'interval', 'text'
		# alias_type 'macaddr',  'text'
		# alias_type 'uuid',     'text'
		#
		# register_type 'money', OID::Money.new
		# There is no PG::TextEncoder::Bytea, because it's simple and more efficient to send bytea-data
		# in binary format, either with PG::BinaryEncoder::Bytea or in Hash param format.
		register_type 0, 'bytea', nil, PG::TextDecoder::Bytea
		register_type 0, 'bool', PG::TextEncoder::Boolean, PG::TextDecoder::Boolean
		# register_type 'bit', OID::Bit.new
		# register_type 'varbit', OID::Bit.new

		register_type 0, 'float4', PG::TextEncoder::Float, PG::TextDecoder::Float
		alias_type 0, 'float8', 'float4'

		register_type 0, 'timestamp', PG::TextEncoder::TimestampWithoutTimeZone, PG::TextDecoder::TimestampWithoutTimeZone
		register_type 0, 'timestamptz', PG::TextEncoder::TimestampWithTimeZone, PG::TextDecoder::TimestampWithTimeZone
		register_type 0, 'date', PG::TextEncoder::Date, PG::TextDecoder::Date
		# register_type 'time', OID::Time.new
		#
		# register_type 'path', OID::Text.new
		# register_type 'point', OID::Point.new
		# register_type 'polygon', OID::Text.new
		# register_type 'circle', OID::Text.new
		# register_type 'hstore', OID::Hstore.new
		register_type 0, 'json', PG::TextEncoder::JSON, PG::TextDecoder::JSON
		alias_type    0, 'jsonb',  'json'
		# register_type 'citext', OID::Text.new
		# register_type 'ltree', OID::Text.new
		#
		register_type 0, 'inet', PG::TextEncoder::Inet, PG::TextDecoder::Inet
		alias_type 0, 'cidr', 'inet'



		register_type 1, 'int2', PG::BinaryEncoder::Int2, PG::BinaryDecoder::Integer
		register_type 1, 'int4', PG::BinaryEncoder::Int4, PG::BinaryDecoder::Integer
		register_type 1, 'int8', PG::BinaryEncoder::Int8, PG::BinaryDecoder::Integer
		alias_type    1, 'oid',  'int2'

		register_type 1, 'text', PG::BinaryEncoder::String, PG::BinaryDecoder::String
		alias_type 1, 'varchar', 'text'
		alias_type 1, 'char', 'text'
		alias_type 1, 'bpchar', 'text'
		alias_type 1, 'xml', 'text'
		alias_type 1, 'name', 'text'

		register_type 1, 'bytea', PG::BinaryEncoder::Bytea, PG::BinaryDecoder::Bytea
		register_type 1, 'bool', PG::BinaryEncoder::Boolean, PG::BinaryDecoder::Boolean
		register_type 1, 'float4', nil, PG::BinaryDecoder::Float
		register_type 1, 'float8', nil, PG::BinaryDecoder::Float
		register_type 1, 'timestamp', nil, PG::BinaryDecoder::TimestampUtc
		register_type 1, 'timestamptz', nil, PG::BinaryDecoder::TimestampUtcToLocal

		self
	end

	# @private
	DEFAULT_TYPE_REGISTRY = PG::BasicTypeRegistry.new.define_default_types

	# Delegate class method calls to DEFAULT_TYPE_REGISTRY
	%i[ register_coder register_type alias_type ].each do |meth|
		self.class.define_method(meth) do |*args|
			warn "PG::BasicTypeRegistry.#{meth} is deprecated. Please use your own instance by PG::BasicTypeRegistry.new instead!"
			DEFAULT_TYPE_REGISTRY.send(meth, *args)
		end
	end
end

# Simple set of rules for type casting common PostgreSQL types to Ruby.
#
# OIDs of supported type casts are not hard-coded in the sources, but are retrieved from the
# PostgreSQL's +pg_type+ table in PG::BasicTypeMapForResults.new .
#
# Result values are type casted based on the type OID of the given result column.
#
# Higher level libraries will most likely not make use of this class, but use their
# own set of rules to choose suitable encoders and decoders.
#
# Example:
#   conn = PG::Connection.new
#   # Assign a default ruleset for type casts of output values.
#   conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)
#   # Execute a query.
#   res = conn.exec_params( "SELECT $1::INT", ['5'] )
#   # Retrieve and cast the result value. Value format is 0 (text) and OID is 20. Therefore typecasting
#   # is done by PG::TextDecoder::Integer internally for all value retrieval methods.
#   res.values  # => [[5]]
#
# PG::TypeMapByOid#build_column_map(result) can be used to generate
# a result independent PG::TypeMapByColumn type map, which can subsequently be used
# to cast #get_copy_data fields:
#
# For the following table:
#   conn.exec( "CREATE TABLE copytable AS VALUES('a', 123, '{5,4,3}'::INT[])" )
#
#   # Retrieve table OIDs per empty result set.
#   res = conn.exec( "SELECT * FROM copytable LIMIT 0" )
#   # Build a type map for common database to ruby type decoders.
#   btm = PG::BasicTypeMapForResults.new(conn)
#   # Build a PG::TypeMapByColumn with decoders suitable for copytable.
#   tm = btm.build_column_map( res )
#   row_decoder = PG::TextDecoder::CopyRow.new type_map: tm
#
#   conn.copy_data( "COPY copytable TO STDOUT", row_decoder ) do |res|
#     while row=conn.get_copy_data
#       p row
#     end
#   end
# This prints the rows with type casted columns:
#   ["a", 123, [5, 4, 3]]
#
# See also PG::BasicTypeMapBasedOnResult for the encoder direction and PG::BasicTypeRegistry for the definition of additional types.
class PG::BasicTypeMapForResults < PG::TypeMapByOid
	include PG::BasicTypeRegistry::Checker

	class WarningTypeMap < PG::TypeMapInRuby
		def initialize(typenames)
			@already_warned = Hash.new{|h, k| h[k] = {} }
			@typenames_by_oid = typenames
		end

		def typecast_result_value(result, _tuple, field)
			format = result.fformat(field)
			oid = result.ftype(field)
			unless @already_warned[format][oid]
				$stderr.puts "Warning: no type cast defined for type #{@typenames_by_oid[oid].inspect} format #{format} with oid #{oid}. Please cast this type explicitly to TEXT to be safe for future changes."
				 @already_warned[format][oid] = true
			end
			super
		end
	end

	def initialize(connection_or_coder_maps, registry: nil)
		@coder_maps = build_coder_maps(connection_or_coder_maps, registry: registry)

		# Populate TypeMapByOid hash with decoders
		@coder_maps.each_format(:decoder).flat_map{|f| f.coders }.each do |coder|
			add_coder(coder)
		end

		typenames = @coder_maps.typenames_by_oid
		self.default_type_map = WarningTypeMap.new(typenames)
	end
end

# Simple set of rules for type casting common PostgreSQL types from Ruby
# to PostgreSQL.
#
# OIDs of supported type casts are not hard-coded in the sources, but are retrieved from the
# PostgreSQL's +pg_type+ table in PG::BasicTypeMapBasedOnResult.new .
#
# This class works equal to PG::BasicTypeMapForResults, but does not define decoders for
# the given result OIDs, but encoders. So it can be used to type cast field values based on
# the type OID retrieved by a separate SQL query.
#
# PG::TypeMapByOid#build_column_map(result) can be used to generate a result independent
# PG::TypeMapByColumn type map, which can subsequently be used to cast query bind parameters
# or #put_copy_data fields.
#
# Example:
#   conn.exec( "CREATE TEMP TABLE copytable (t TEXT, i INT, ai INT[])" )
#
#   # Retrieve table OIDs per empty result set.
#   res = conn.exec( "SELECT * FROM copytable LIMIT 0" )
#   # Build a type map for common ruby to database type encoders.
#   btm = PG::BasicTypeMapBasedOnResult.new(conn)
#   # Build a PG::TypeMapByColumn with encoders suitable for copytable.
#   tm = btm.build_column_map( res )
#   row_encoder = PG::TextEncoder::CopyRow.new type_map: tm
#
#   conn.copy_data( "COPY copytable FROM STDIN", row_encoder ) do |res|
#     conn.put_copy_data ['a', 123, [5,4,3]]
#   end
# This inserts a single row into copytable with type casts from ruby to
# database types.
class PG::BasicTypeMapBasedOnResult < PG::TypeMapByOid
	include PG::BasicTypeRegistry::Checker

	def initialize(connection_or_coder_maps, registry: nil)
		@coder_maps = build_coder_maps(connection_or_coder_maps, registry: registry)

		# Populate TypeMapByOid hash with encoders
		@coder_maps.each_format(:encoder).flat_map{|f| f.coders }.each do |coder|
			add_coder(coder)
		end
	end
end

# Simple set of rules for type casting common Ruby types to PostgreSQL.
#
# OIDs of supported type casts are not hard-coded in the sources, but are retrieved from the
# PostgreSQL's pg_type table in PG::BasicTypeMapForQueries.new .
#
# Query params are type casted based on the class of the given value.
#
# Higher level libraries will most likely not make use of this class, but use their
# own derivation of PG::TypeMapByClass or another set of rules to choose suitable
# encoders and decoders for the values to be sent.
#
# Example:
#   conn = PG::Connection.new
#   # Assign a default ruleset for type casts of input and output values.
#   conn.type_map_for_queries = PG::BasicTypeMapForQueries.new(conn)
#   # Execute a query. The Integer param value is typecasted internally by PG::BinaryEncoder::Int8.
#   # The format of the parameter is set to 0 (text) and the OID of this parameter is set to 20 (int8).
#   res = conn.exec_params( "SELECT $1", [5] )
class PG::BasicTypeMapForQueries < PG::TypeMapByClass
	# Helper class for submission of binary strings into bytea columns.
	#
	# Since PG::BasicTypeMapForQueries chooses the encoder to be used by the class of the submitted value,
	# it's necessary to send binary strings as BinaryData.
	# That way they're distinct from text strings.
	# Please note however that PG::BasicTypeMapForResults delivers bytea columns as plain String
	# with binary encoding.
	#
	#   conn.type_map_for_queries = PG::BasicTypeMapForQueries.new(conn)
	#   conn.exec("CREATE TEMP TABLE test (data bytea)")
	#   bd = PG::BasicTypeMapForQueries::BinaryData.new("ab\xff\0cd")
	#   conn.exec_params("INSERT INTO test (data) VALUES ($1)", [bd])
	class BinaryData < String
	end

	class UndefinedEncoder < RuntimeError
	end

	include PG::BasicTypeRegistry::Checker

	# Create a new type map for query submission
	#
	# Options:
	# * +registry+: Custom type registry, nil for default global registry
	# * +if_undefined+: Optional +Proc+ object which is called, if no type for an parameter class is not defined in the registry.
	def initialize(connection_or_coder_maps, registry: nil, if_undefined: nil)
		@coder_maps = build_coder_maps(connection_or_coder_maps, registry: registry)
		@array_encoders_by_klass = array_encoders_by_klass
		@encode_array_as = :array
		@if_undefined = if_undefined || proc { |oid_name, format|
			raise UndefinedEncoder, "no encoder defined for type #{oid_name.inspect} format #{format}"
		}
		init_encoders
	end

	# Change the mechanism that is used to encode ruby array values
	#
	# Possible values:
	# * +:array+ : Encode the ruby array as a PostgreSQL array.
	#   The array element type is inferred from the class of the first array element. This is the default.
	# * +:json+ : Encode the ruby array as a JSON document.
	# * +:record+ : Encode the ruby array as a composite type row.
	# * <code>"_type"</code> : Encode the ruby array as a particular PostgreSQL type.
	#   All PostgreSQL array types are supported.
	#   If there's an encoder registered for the elements +type+, it will be used.
	#   Otherwise a string conversion (by +value.to_s+) is done.
	def encode_array_as=(pg_type)
		case pg_type
			when :array
			when :json
			when :record
			when /\A_/
			else
				raise ArgumentError, "invalid pg_type #{pg_type.inspect}"
		end

		@encode_array_as = pg_type

		init_encoders
	end

	attr_reader :encode_array_as

	private

	def init_encoders
		coders.each { |kl, c| self[kl] = nil } # Clear type map
		populate_encoder_list
		@textarray_encoder = coder_by_name(0, :encoder, '_text')
	end

	def coder_by_name(format, direction, name)
		check_format_and_direction(format, direction)
		@coder_maps.map_for(format, direction).coder_by_name(name)
	end

	def undefined(name, format)
		@if_undefined.call(name, format)
	end

	def populate_encoder_list
		DEFAULT_TYPE_MAP.each do |klass, selector|
			if Array === selector
				format, name, oid_name = selector
				coder = coder_by_name(format, :encoder, name).dup
				if coder
					if oid_name
						oid_coder = coder_by_name(format, :encoder, oid_name)
						if oid_coder
							coder.oid = oid_coder.oid
						else
							undefined(oid_name, format)
						end
					else
						coder.oid = 0
					end
					self[klass] = coder
				else
					undefined(name, format)
				end
			else

				case @encode_array_as
					when :array
						self[klass] = selector
					when :json
						self[klass] = PG::TextEncoder::JSON.new
					when :record
						self[klass] = PG::TextEncoder::Record.new type_map: self
					when /\A_/
						coder = coder_by_name(0, :encoder, @encode_array_as)
						if coder
							self[klass] = coder
						else
							undefined(@encode_array_as, format)
						end
					else
						raise ArgumentError, "invalid pg_type #{@encode_array_as.inspect}"
				end
			end
		end
	end

	def array_encoders_by_klass
		DEFAULT_ARRAY_TYPE_MAP.inject({}) do |h, (klass, (format, name))|
			h[klass] = coder_by_name(format, :encoder, name)
			h
		end
	end

	def get_array_type(value)
		elem = value
		while elem.kind_of?(Array)
			elem = elem.first
		end
		@array_encoders_by_klass[elem.class] ||
				elem.class.ancestors.lazy.map{|ancestor| @array_encoders_by_klass[ancestor] }.find{|a| a } ||
				@textarray_encoder
	end

	DEFAULT_TYPE_MAP = {
		TrueClass => [1, 'bool', 'bool'],
		FalseClass => [1, 'bool', 'bool'],
		# We use text format and no type OID for numbers, because setting the OID can lead
		# to unnecessary type conversions on server side.
		Integer => [0, 'int8'],
		Float => [0, 'float8'],
		BigDecimal => [0, 'numeric'],
		Time => [0, 'timestamptz'],
		# We use text format and no type OID for IPAddr, because setting the OID can lead
		# to unnecessary inet/cidr conversions on the server side.
		IPAddr => [0, 'inet'],
		Hash => [0, 'json'],
		Array => :get_array_type,
		BinaryData => [1, 'bytea'],
	}

	DEFAULT_ARRAY_TYPE_MAP = {
		TrueClass => [0, '_bool'],
		FalseClass => [0, '_bool'],
		Integer => [0, '_int8'],
		String => [0, '_text'],
		Float => [0, '_float8'],
		BigDecimal => [0, '_numeric'],
		Time => [0, '_timestamptz'],
		IPAddr => [0, '_inet'],
	}

end
