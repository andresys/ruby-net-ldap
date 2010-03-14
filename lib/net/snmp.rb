# NET::SNMP
#
#----------------------------------------------------------------------------
#
# Copyright (C) 2006-07 by Francis Cianfrocca. All Rights Reserved.
#
# Gmail: garbagecat10
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
#---------------------------------------------------------------------------
module Net
  class SNMP
    application_primitive = {
      1 => :integer, # Counter32, (RFC2578 sec 2)
      2 => :integer, # Gauge32 or Unsigned32, (RFC2578 sec 2)
      3 => :integer # TimeTicks32, (RFC2578 sec 2)
    }
    application = {
      :primitive => application_primitive,
      :constructed => { }
    }

    context_constructed = {
      0 => :array, # GetRequest PDU (RFC1157 pgh 4.1.2)
      1 => :array, # GetNextRequest PDU (RFC1157 pgh 4.1.3)
      2 => :array # GetResponse PDU (RFC1157 pgh 4.1.4)
    }
    context = {
      :primitive => { },
      :constructed => context_constructed,
    }

    AsnSyntax = Net::BER.compile_syntax(:application => application,
                                        :context_specific => context)

    # SNMP 32-bit counter. Defined in RFC1155 (Structure of Mangement
    # Information), section 6. A 32-bit counter is an ASN.1 application [1]
    # implicit unsigned integer with a range from 0 to 2^^32 - 1.
    class Counter32
      def initialize value
        @value = value
      end
      def to_ber
        @value.to_ber_application(1)
      end
    end

    # SNMP 32-bit gauge. Defined in RFC1155 (Structure of Mangement
    # Information), section 6. A 32-bit counter is an ASN.1 application [2]
    # implicit unsigned integer. This is also indistinguishable from
    # Unsigned32. (Need to alias them.)
    class Gauge32
      def initialize value
        @value = value
      end
      def to_ber
        @value.to_ber_application(2)
      end
    end

    # SNMP 32-bit timer-ticks. Defined in RFC1155 (Structure of Mangement
    # Information), section 6. A 32-bit counter is an ASN.1 application [3]
    # implicit unsigned integer.
    class TimeTicks32
      def initialize value
        @value = value
      end
      def to_ber
        @value.to_ber_application(3)
      end
    end
  end

  class SnmpPdu
    class Error < StandardError; end

    PduTypes = [
      :get_request,
      :get_next_request,
      :get_response,
      :set_request,
      :trap
    ]
    ErrorStatusCodes = { # Per RFC1157, pgh 4.1.1
      0 => "noError",
      1 => "tooBig",
      2 => "noSuchName",
      3 => "badValue",
      4 => "readOnly",
      5 => "genErr"
    }

    class << self
      def parse(ber_object)
        n = new
        n.__send__(:parse, ber_object)
        n
      end
    end

    attr_reader :version, :community, :pdu_type, :variables, :error_status
    attr_accessor :request_id, :error_index

    def initialize(args = {})
      @version = args[:version] || 0
      @community = args[:community] || "public"
      # leave nil unless specified; there's no reasonable default value.
      @pdu_type = args[:pdu_type]
      @error_status = args[:error_status] || 0
      @error_index = args[:error_index] || 0
      @variables = args[:variables] || []
    end

    def parse(ber_object) #:nodoc:
      begin
        parse_ber_object(ber_object)
      rescue Error
        # Pass through any SnmpPdu::Error instances
        raise $!
      rescue
        # Wrap any basic parsing error so it becomes a PDU-format error
        raise Error.new("snmp-pdu format error")
      end
    end
    private :parse

    def parse_ber_object(ber_object) #:nodoc:
      __send__(:version=, ber_object[0].to_i)
      __send__(:community=, ber_object[1].to_s)

      data = ber_object[2]
      case (app_tag = data.ber_identifier & 31)
      when 0
        __send__(:pdu_type=, :get_request)
        parse_get_request(data)
      when 1
        __send__(:pdu_type=, :get_next_request)
        # This PDU is identical to get-request except for the type.
        parse_get_request(data)
      when 2
        __send__(:pdu_type=, :get_response)
        # This PDU is identical to get-request except for the type,
        # the error_status and error_index values are meaningful,
        # and the fact that the variable bindings will be non-null.
        parse_get_response(data)
      else
        raise Error.new("unknown snmp-pdu type: #{app_tag}")
      end
    end
    private :parse_ber_object

    #--
    # Defined in RFC1157, pgh 4.1.2.
    #++
    def parse_get_request(data) #:nodoc:
      __send__(:request_id=, data[0].to_i)
      # data[1] is error_status, always zero.
      # data[2] is error_index, always zero.
      __send__(:error_status=, 0)
      __send__(:error_index=, 0)
      data[3].each { |n, v|
        # A variable-binding, of which there may be several, consists of an
        # OID and a BER null. We're ignoring the null, we might want to
        # verify it instead.
        unless v.is_a?(Net::BER::BerIdentifiedNull)
          raise Error.new(" invalid variable-binding in get-request")
        end
        add_variable_binding(n, nil)
      }
    end
    private :parse_get_request

    #--
    # Defined in RFC1157, pgh 4.1.4
    #++
    def parse_get_response(data)
      __send__(:request_id=, data[0].to_i)
      __send__(:error_status=, data[1].to_i)
      __send__(:error_index=, data[2].to_i)
      data[3].each { |n, v|
        # A variable-binding, of which there may be several,
        # consists of an OID and a BER null.
        # We're ignoring the null, we might want to verify it instead.
        add_variable_binding(n, v)
      }
    end
    private :parse_get_response

    def version=(ver)
      raise Error.new("unknown snmp-version: #{ver}") unless [0, 2].include?(ver)
      @version = ver
    end

    def pdu_type=(t)
      raise Error.new("unknown pdu-type: #{t}") unless PduTypes.include?(t)
      @pdu_type = t
    end

    def error_status=(es)
      raise Error.new("unknown error-status: #{es}") unless ErrorStatusCodes.has_key?(es)
      @error_status = es
    end

    def community=(c)
      @community = c.to_s
    end

    #--
    # Syntactic sugar
    #++
    def add_variable_binding(name, value = nil)
      @variables ||= []
      @variables << [name, value]
    end

    def to_ber_string
      [ version.to_ber, community.to_ber, pdu_to_ber_string ].to_ber_sequence
    end

    def variables_to_ber_sequence(response = false)
      vars = @variables.map { |n, v|
        [
          n.to_ber_oid, response ? v.to_ber : Net::BER::Null.to_ber
        ].to_ber_sequence
      }
      [ vars ].to_ber_sequence
    end
    private :variables_to_ber_sequence

    #--
    # Helper method that returns a PDU payload in BER form, depending on the
    # PDU type.
    #++
    def pdu_to_ber_string
      case pdu_type
      when :get_request
        [
          request_id.to_ber,
          error_status.to_ber,
          error_index.to_ber,
          variables_to_ber_sequence,
        ].to_ber_contextspecific(0)
      when :get_next_request
        [
          request_id.to_ber,
          error_status.to_ber,
          error_index.to_ber,
          variables_to_ber_sequence,
        ].to_ber_contextspecific(1)
      when :get_response
        [
          request_id.to_ber,
          error_status.to_ber,
          error_index.to_ber,
          variables_to_ber_sequence(true),
        ].to_ber_contextspecific(2)
      else
        raise Error.new( "unknown pdu-type: #{pdu_type}")
      end
    end
    private :pdu_to_ber_string
  end
end

