#!/usr/bin/env bin/crystal -run
require "spec"
require "../../../../bootstrap/crystal/parser"

def it_parses(string, expected_node)
  it "parses #{string}" do
    node = Crystal::Parser.parse(string)
    node.should eq(Crystal::Expressions.from expected_node)
  end
end

describe "Parser" do
  it_parses "nil", Crystal::NilLiteral.new
end
