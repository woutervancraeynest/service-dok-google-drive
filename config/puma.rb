max_threads_count = Integer(ENV.fetch("MAX_THREADS", "4"))
min_threads_count = Integer(ENV.fetch("MIN_THREADS", "0"))

threads min_threads_count, max_threads_count
port ENV.fetch("PORT", "8080")
environment ENV.fetch("RACK_ENV", "production")
