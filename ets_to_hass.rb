#!/usr/bin/env ruby
# Laurent Martin
# translate configuration from ETS into KNXWeb and Home Assistant
require 'zip'
require 'xmlsimple'
require 'yaml'
require 'json'
require 'logger'

class ConfigurationImporter
  ETS_EXT='.knxproj'
  ENV_DEBUG='DEBUG'
  ENV_GADDRSTYLE='GADDRSTYLE'
  GADDR_CONV={
    Free:       lambda{|a|a.to_s},
    TwoLevel:   lambda{|a|[(a>>11)&31,a&2047].join('/')},
    ThreeLevel: lambda{|a|[(a>>11)&31,(a>>8)&7,a&255].join('/')}
  }
  private_constant :ETS_EXT

  def self.my_dig(entry_point,path)
    path.each do |n|
      entry_point=entry_point[n]
      raise "ERROR: cannot find level #{n} in xml" if entry_point.nil?
      # because we use ForceArray
      entry_point=entry_point.first
      raise "ERROR: expect array with one element in #{n}" if entry_point.nil?
    end
    return entry_point
  end

  def process_ga(ga)
    # build object for each group address
    group={
      name:             ga['Name'].freeze,                            # ETS: name field
      description:      ga['Description'].freeze,                     # ETS: description field
      address:          @addrparser.call(ga['Address'].to_i).freeze,  # group address as string. e.g. "x/y/z" depending on project style
      datapoint:        nil,                                          # datapoint type as string "x.00y"
      objs:             [],                                           # objects ids, it may be in multiple objects
      custom:           {}                                            # modified by lambda
    }
    if ga['DatapointType'].nil?
      @logger.warn("no datapoint type for #{group[:address]} : #{group[:name]}, group address is skipped")
      return
    end
    # parse datapoint for easier use
    if m = ga['DatapointType'].match(/^DPST-([0-9]+)-([0-9]+)$/)
      # datapoint type as string x.00y
      group[:datapoint]=sprintf('%d.%03d',m[1].to_i,m[2].to_i) # no freeze
    else
      @logger.warn("cannot parse datapoint : #{ga['DatapointType']}, group is skipped")
      return
    end
    # Index is the internal Id in xml file
    @data[:ga][ga['Id'].freeze]=group.freeze
    @logger.debug("group: #{group}")
  end

  def process_group_ranges(gr)
    gr['GroupRange'].each{|sgr|process_group_ranges(sgr)} if gr.has_key?('GroupRange')
    gr['GroupAddress'].each{|ga|process_ga(ga)} if gr.has_key?('GroupAddress')
  end

  # from knx_master.xml in project file
  KNOWN_FUNCTIONS=[:custom,:switchable_light,:dimmable_light,:sun_protection,:heating_radiator,:heating_floor,:dimmable_light,:sun_protection,:heating_switching_variable,:heating_continuous_variable]

  def process_space(space,info=nil)
    @logger.debug("#{space['Type']}: #{space['Name']}")
    info=info.nil? ? {} : info.dup
    if space.has_key?('Space')
      # get floor when we have it
      info[:floor]=space['Name'] if space['Type'].eql?('Floor')
      space['Space'].each{|s|process_space(s,info)}
    end
    # Functions are objects
    if space.has_key?('Function')
      # we assume the object is directly in the room
      info[:room]=space['Name']
      # loop on group addresses
      space['Function'].each do |f|
        @logger.debug("function #{f}")
        # ignore functions without group address
        next unless f.has_key?('GroupAddressRef')
        if m=f['Type'].match(/^FT-([0-9])$/)
          type=KNOWN_FUNCTIONS[m[1].to_i]
        else
          raise "unknown function type: #{f['Type']}"
        end
        o={
          name:   f['Name'].freeze,
          type:   type,
          ga:     f['GroupAddressRef'].map{|g|g['RefId'].freeze},
          custom: {} # custom values
        }.merge(info)
        # store reference to this object in the GAs
        o[:ga].each do |g|
          next unless @data[:ga].has_key?(g)
          @data[:ga][g][:objs].push(f['Id'])
        end
        @logger.debug("function: #{o}")
        @data[:ob][f['Id']]=o.freeze
      end
    end
  end

  def read_file(file)
    raise "ETS file must end with #{ETS_EXT}" unless file.end_with?(ETS_EXT)
    project={}
    # read ETS5 file and get project file
    Zip::File.open(file) do |zip_file|
      zip_file.each do |entry|
        case entry.name
        when %r{P-[^/]+/project\.xml$};project[:info]=XmlSimple.xml_in(entry.get_input_stream.read, {'ForceArray' => true})
        when %r{P-[^/]+/0\.xml$};project[:data]=XmlSimple.xml_in(entry.get_input_stream.read, {'ForceArray' => true})
        end
      end
    end
    return project
  end

  attr_reader :data

  def initialize(file)
    @data={ob: {}, ga: {}}
    # log to stderr, so that redirecting stdout captures only generated data
    @logger = Logger.new(STDERR)
    @logger.level=ENV.has_key?(ENV_DEBUG) ? ENV[ENV_DEBUG] : Logger::INFO
    project=read_file(file)
    proj_info=self.class.my_dig(project[:info],['Project','ProjectInformation'])
    group_addr_style=ENV.has_key?(ENV_GADDRSTYLE) ? ENV[ENV_GADDRSTYLE] : proj_info['GroupAddressStyle']
    @logger.info("Using project #{proj_info['Name']}, address style: #{group_addr_style}")
    # set group address formatter according to project settings
    @addrparser=GADDR_CONV[group_addr_style.to_sym]
    raise "Error: no such style #{group_addr_style} in #{GADDR_CONV.keys}" if @addrparser.nil?
    installation=self.class.my_dig(project[:data],['Project','Installations','Installation'])
    # process group ranges
    process_group_ranges(self.class.my_dig(installation,['GroupAddresses','GroupRanges']))
    process_space(self.class.my_dig(installation,['Locations']))
  end

  def generate_homeass
    haknx={}
    # warn of group addresses that will not be used (you can fix in custom lambda)
    @data[:ga].values.select{|ga|ga[:objs].empty?}.each do |ga|
      @logger.warn("group not in object: #{ga[:address]}: Create custom object in lambda if needed , or use ETS to create functions")
    end
    @data[:ob].values.each do |o|
      new_obj=o[:custom].has_key?(:ha_init) ? o[:custom][:ha_init] : {}
      new_obj['name']=o[:name] unless new_obj.has_key?('name')
      # compute object type
      ha_obj_type=o[:custom][:ha_type] || case o[:type]
      when :switchable_light,:dimmable_light;'light'
      when :sun_protection;'cover'
      when :custom,:heating_continuous_variable,:heating_floor,:heating_radiator,:heating_switching_variable
        @logger.warn("function type not implemented for #{o[:name]}/#{o[:room]}: #{o[:type]}");next
      else @logger.error("function type not supported for #{o[:name]}/#{o[:room]}, please report: #{o[:type]}");next
      end
      # process all group addresses in function
      o[:ga].each do |garef|
        ga=@data[:ga][garef]
        next if ga.nil?
        # find property name based on datapoint
        ha_address_type=ga[:custom][:ha_address_type] || case ga[:datapoint]
        when '1.001';'address' # switch on/off or state
        when '1.008';'move_long_address' # up/down
        when '1.010';'stop_address' # stop
        when '1.011';'state_address' # switch state
        when '3.007';@logger.debug("#{ga[:address]}(#{ha_obj_type}:#{ga[:datapoint]}:#{ga[:name]}): ignoring datapoint");next # dimming control: used by buttons
        when '5.001' # percentage 0-100
          # custom code tells what is state
          case ha_obj_type
          when 'light'; 'brightness_address'
          when 'cover'; 'position_address'
          else @logger.warn("#{ga[:address]}(#{ha_obj_type}:#{ga[:datapoint]}:#{ga[:name]}): no mapping for datapoint #{ga[:datapoint]}");next
          end
        else
          @logger.warn("#{ga[:address]}(#{ha_obj_type}:#{ga[:datapoint]}:#{ga[:name]}): no mapping for datapoint #{ga[:datapoint]}");next
        end
        if ha_address_type.nil?
          @logger.warn("#{ga[:address]}(#{ha_obj_type}:#{ga[:datapoint]}:#{ga[:name]}): unexpected nil property name")
          next
        end
        if new_obj.has_key?(ha_address_type)
          @logger.error("#{ga[:address]}(#{ha_obj_type}:#{ga[:datapoint]}:#{ga[:name]}): ignoring for #{ha_address_type} already set with #{new_obj[ha_address_type]}")
          next
        end
        new_obj[ha_address_type]=ga[:address]
      end
      haknx[ha_obj_type]=[] unless haknx.has_key?(ha_obj_type)
      haknx[ha_obj_type].push(new_obj)
    end
    return {'knx'=>haknx}.to_yaml
  end

  # https://sourceforge.net/p/linknx/wiki/Object_Definition_section/
  def generate_linknx
    return @data[:ga].values.sort{|a,b|a[:address]<=>b[:address]}.map do |ga|
      linknx_disp_name=ga[:custom][:linknx_disp_name] || ga[:name]
      %Q(        <object type="#{ga[:datapoint]}" id="id_#{ga[:address].gsub('/','_')}" gad="#{ga[:address]}" init="request">#{linknx_disp_name}</object>)
    end.join("\n")
  end

end

GENPREFIX='generate_'
genformats=(ConfigurationImporter.instance_methods-ConfigurationImporter.superclass.instance_methods).
select{|m|m.start_with?(GENPREFIX)}.
map{|m|m[GENPREFIX.length..-1]}
if ARGV.length < 2 or ARGV.length > 3
  STDERR.puts("Usage: #{$0} [#{genformats.join('|')}] <etsprojectfile>.knxproj [custom lambda]")
  STDERR.puts("env var #{ConfigurationImporter::ENV_DEBUG}: debug, info, warn, error")
  STDERR.puts("env var #{ConfigurationImporter::ENV_GADDRSTYLE}: #{ConfigurationImporter::GADDR_CONV.keys.map{|i|i.to_s}.join(', ')} to override value in project")
  Process.exit(1)
end
format=ARGV.shift
infile=ARGV.shift
custom_lambda=ARGV.shift || File.join(File.dirname(__FILE__),'default_custom.rb')
raise "Error: no such output format: #{format}" unless genformats.include?(format)
# read and parse file
knxconf=ConfigurationImporter.new(infile)
# apply special code if provided
eval(File.read(custom_lambda)).call(knxconf) unless custom_lambda.nil?
$stdout.write(knxconf.send("#{GENPREFIX}#{format}".to_sym))
