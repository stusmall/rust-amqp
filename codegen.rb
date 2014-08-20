gem 'json'
require 'json'

def pad_str(count, str)
  str.lines.map{|line| "#{" "*count}#{line.lstrip}" }.join()
end

def titleize(name)
  name[0].upcase+name[1..-1]
end

def normalize_argument(argument_name)
  argument_name.tr("-","_").gsub(/^type$/, "_type")
end

def normalize_method(klass)
  klass.gsub(/(\-.)/){|c| c[1].upcase}
end

def map_type_to_rust(type)
  case type
  when "octet"
    "u8"
  when "long"
    "u32"
  when "longlong"
    "u64"
  when "short"
    "u16"
  when "bit"
    'bool'
  when "shortstr"
    # 'Vec<u8>'
    String
  when "longstr"
    # 'Vec<u8>'
    String
  when "table"
    "Table"
  when "timestamp"
    "u64"
  else
    raise "Uknown type: #{type}"
  end
end

def read_type(name, type)
  case type
  when "octet"
    "let #{name} = reader.read_byte().unwrap();"
  when "long"
    "let #{name} = reader.read_be_u32().unwrap();"
  when "longlong"
    "let #{name} = reader.read_be_u64().unwrap();"
  when "short"
    "let #{name} = reader.read_be_u16().unwrap();"
  when "bit"
    raise "Cant read bit here..."
  when "shortstr"
    "let size = reader.read_byte().unwrap() as uint;
    let #{name} = String::from_utf8_lossy(reader.read_exact(size).unwrap().as_slice()).into_string();"
  when "longstr"
    "let size = reader.read_be_u32().unwrap() as uint;
    let #{name} = String::from_utf8_lossy(reader.read_exact(size).unwrap().as_slice()).into_string();"
  when "table"
    "let #{name} = decode_table(&mut reader).unwrap();"
  when "timestamp"
    "let #{name} = reader.read_be_u64().unwrap();"
  else
    raise "Unknown type: #{type}"
  end
end

def write_type(name, type)
  case type
  when "octet"
    "writer.write_u8(self.#{name}).unwrap();"
  when "long"
    "writer.write_be_u32(self.#{name}).unwrap();"
  when "longlong"
    "writer.write_be_u64(self.#{name}).unwrap();"
  when "short"
    "writer.write_be_u16(self.#{name}).unwrap();"
  when "bit"
    raise "Cant write bit here..."
  when "shortstr"
    "writer.write_u8(self.#{name}.len() as u8).unwrap();
    writer.write(self.#{name}.as_bytes()).unwrap();"
  when "longstr"
    "writer.write_be_u32(self.#{name}.len() as u32).unwrap();
    writer.write(self.#{name}.as_bytes()).unwrap();"
  when "table"
    "encode_table(&mut writer, self.#{name}.clone()).unwrap();"
  when "timestamp"
    "writer.write_be_u64(self.#{name}).unwrap();"
  else
    raise "Unknown type: #{type}"
  end
end

def map_domain(domain)
  DOMAINS[domain]
end

spec_file = 'amqp-rabbitmq-0.9.1.json'
SPEC = JSON.load(File.read(spec_file))
DOMAINS = Hash[SPEC["domains"]]


puts "// This file is autogenerated. Do not edit.
// To make some changes, edit codegen.rb and run make\n"

puts <<-RUST

pub trait Method {
    fn decode(method_frame: MethodFrame) -> Option<Self>;
    fn encode(&self) -> Vec<u8>;
    fn name(&self) -> &'static str;
    fn id(&self) -> u16;
    fn class_id(&self) -> u16;
}

pub struct MethodFrame {
    pub class_id: u16,
    pub method_id: u16,
    pub arguments: Vec<u8>
}

impl MethodFrame {
    pub fn method_name(&self) -> &'static str {
        match (self.class_id, self.method_id) {
RUST
matches = SPEC["classes"].flat_map do |klass|
  klass["methods"].map do |method|
    "(#{klass["id"]}, #{method["id"]}) => \"#{klass["name"]}.#{method["name"]}\""
  end
end
matches << "(_,_) => \"UNKNOWN\""
puts pad_str(12, matches.join(",\n"))

puts <<-RUST
        }
    }
}
RUST

SPEC["classes"].each do |klass|
  struct_name = titleize(klass["name"])
  puts "#[allow(unused_imports)]"
  puts "pub mod #{klass["name"]} {"
  puts "use std::io::{MemReader, MemWriter};\n"
  puts "use table::{Table, decode_table, encode_table};"
  puts "use std::collections::bitv;"
  puts "use std::collections::bitv::Bitv;"
  puts "use protocol;"
  puts "use protocol::Method;"
  puts ""

  klass["methods"].each do |method|
    method_name = normalize_method titleize(method["name"])
    properties = method["properties"]

    fields = method["arguments"].map do |argument|
      rust_type = map_type_to_rust argument["domain"] ? map_domain(argument["domain"]) : argument["type"]
      "pub #{normalize_argument argument["name"]}: #{rust_type}"
    end

    #struct definition
    puts "// Method #{method["id"]}:#{method["name"]}"
    puts "#[deriving(Show)]"
    if fields.any?
      puts "pub struct #{method_name} {"
      puts pad_str(4, fields.join(",\n"))
      puts "}"
    else
      puts "pub struct #{method_name};"
    end

    #impl Method for struct
    puts "impl Method for #{method_name} {"
    puts "    fn name(&self) -> &'static str {"
    puts "        \"#{klass["name"]}.#{method["name"]}\""
    puts "    }"
    puts "    fn id(&self) -> u16 {"
    puts "        #{method["id"]}"
    puts "    }"
    puts "    fn class_id(&self) -> u16 {"
    puts "        #{klass["id"]}"
    puts "    }"

    #Decode
    if method["arguments"].any?
      puts "    fn decode(method_frame: protocol::MethodFrame) -> Option<#{method_name}> {"
      puts "        if method_frame.class_id != #{klass["id"]} || method_frame.method_id != #{method["id"]} {"
      puts "           return None;"
      puts "        }"
      puts "        let mut reader = MemReader::new(method_frame.arguments);"
      n_bits = 0
      method["arguments"].each do |argument|
        type = argument["domain"] ? map_domain(argument["domain"]) : argument["type"]
        if type == "bit"
          if n_bits == 0
            puts pad_str(8, "let byte = reader.read_byte().unwrap();")
            puts pad_str(8, "let bits = bitv::from_bytes([byte]);")
          end
          puts pad_str(8, "let #{normalize_argument(argument["name"])} = bits.get(#{n_bits});")
          n_bits += 1
          if n_bits == 8
            n_bits = 0
          end
        else
          n_bits = 0
          puts pad_str(8, "#{read_type(normalize_argument(argument["name"]), type)}")
        end
      end
      fields = method["arguments"].map{|arg| "#{normalize_argument arg["name"]}: #{normalize_argument arg["name"]}"}
      puts "        Some(#{method_name} { #{fields.join(", ")} })"
      puts "    }"
    else
      puts "    fn decode(method_frame: protocol::MethodFrame) -> Option<#{method_name}> {"
      puts "        if method_frame.class_id != #{klass["id"]} || method_frame.method_id != #{method["id"]} {"
      puts "           return None;"
      puts "        }"
      puts "        Some(#{method_name})"
      puts "    }"
    end#decode

    #Encode
    if method["arguments"].any?
      puts "    fn encode(&self) -> Vec<u8> {"
      puts "        let mut writer = MemWriter::new();"
      n_bits = 0
      method["arguments"].each do |argument|
        type = argument["domain"] ? map_domain(argument["domain"]) : argument["type"]
        if type == "bit"
          if n_bits == 0
            puts pad_str(8, "let mut bits = Bitv::new();")
          end
          puts pad_str(8, "bits.push(self.#{normalize_argument(argument["name"])});")
          n_bits += 1
        else
          if n_bits > 0
            puts pad_str(8, "writer.write(bits.to_bytes().as_slice()).unwrap();")
            n_bits = 0
          end
          puts pad_str(8, "#{write_type(normalize_argument(argument["name"]), type)}")
        end
      end
      puts pad_str(8, "writer.write(bits.to_bytes().as_slice()).unwrap();") if n_bits > 0 #if bits were the last element
      puts pad_str(8,"writer.unwrap()")
      puts pad_str(4,"}")
    else
      puts pad_str(4, "fn encode(&self) -> Vec<u8> {")
      puts pad_str(8,"vec!()")
      puts pad_str(4,"}")
    end #encode

    puts "}"
  end
  puts "}"
end
