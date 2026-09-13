require "rack/test"
require "rspec"
require "ostruct"

ENV["RACK_ENV"] = "test"

require_relative "../app"

RSpec.configure do |config|
  config.include Rack::Test::Methods

  def app
    DokService
  end

  def call_tool(tool, params: {}, context: {})
    post "/call", {
      tool: tool,
      params: params,
      context: context
    }.to_json, { "CONTENT_TYPE" => "application/json" }
  end
end
