# Bound regex matching globally to prevent ReDoS attacks against Puma workers.
# Individual regexes can override with Regexp.new(pattern, timeout: ...).
Regexp.timeout = 1.0
