# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Specifies the `address` that Puma will bind to. THE CONTAINER CASE, and it
# is a measured defect rather than a default: this service's own compose maps
# `3000:3000` and `billing/bin/rails server` bound `tcp://localhost:3000`,
# which answers from the container's own loopback and refuses every request
# Docker forwards from a published port (measured on the launch stack: the
# container reported healthy, its own runner answered `200` on
# `127.0.0.1:3000/readyz`, and the host's curl earned `Connection reset by
# peer`). Rails' `port` line sets the port and leaves the bind to Puma's own
# default, which in development is `localhost`; a container has no loopback a
# request from outside it can reach, so the bind is `0.0.0.0` unless an
# operator deliberately narrows it.
#
# `BINDING` is the variable, and the NAME is the finding. `railties`'
# `server_command.rb` defaults the host to `localhost` in development and
# `0.0.0.0` elsewhere, reads `ENV["BINDING"]` to override it, and hands Puma
# its own `-b` ON THE COMMAND LINE — which wins over anything in this file.
# So a `bind` in this file does nothing in development: the CLI's `-b` beats
# it, and the FIRST version of this fix (a `bind` here, plus a `BIND` variable
# that `server_command.rb` never reads) left Puma binding `tcp://localhost:3000`
# inside the launch stack while the image's own runner answered 200 — the
# bind was set and the request still died at the host's `Connection reset`.
#
# SO THIS IS NOT A CONFIG LINE, and that is the point of the paragraph: the
# fix belongs where the default is decided, in the environment, and this line
# exists to say so. `BINDING=0.0.0.0` is set in the compose files (this
# service's own and the launch's) rather than here, because a container's
# eth0 and a laptop's loopback need the same address and a developer who wants
# a narrower one still overrides the variable. THIS LINE IS A DELIBERATE
# ABSENCE: a `bind` here would look like the fix and would not be.


# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments.
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
