module Tools
  module GoogleAuth
    def with_google_client(context)
      yield GoogleWorkspace::Client.from_context(context)
    rescue GoogleWorkspace::ConfigurationError => e
      { error: e.message }
    rescue GoogleWorkspace::AuthenticationError
      { error: "Google authentication failed. Reconnect the Google service." }
    rescue GoogleWorkspace::ScopeError => e
      { error: e.message }
    rescue GoogleWorkspace::ApiError => e
      { error: e.message }
    end
  end
end
