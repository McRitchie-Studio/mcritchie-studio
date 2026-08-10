# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# to prioritize throughput over latency.
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

# Run Puma in cluster mode in production so a few slow renders cannot queue the
# whole site (2026-08-09 postmortem: one Basic dyno, no workers line, 3 threads
# = 3 TOTAL concurrency; a request swarm turned that into 2,293 H12s in under
# three minutes). Development and worktree stacks stay single-process for boot
# speed and debuggability, matching the Rails-generated production gate.
#
# WEB_CONCURRENCY defaults to 2 EXPLICITLY, never to processor count — Heroku
# dynos report the host's vCPUs (8 on Basic), and 8 workers would blow both the
# 512MB dyno and the connection ceiling below. Puma auto-enables preload_app
# (copy-on-write) whenever workers > 1.
#
# THE CEILING THAT SIZES THIS: the board Postgres is Heroku essential-0 with a
# HARD 20-connection limit, shared by every process that boots this app. Worst
# case at these defaults — each live thread holds at most 1 connection, and the
# per-process Active Record pool (database.yml: RAILS_MAX_THREADS, fallback 5)
# caps any runaway:
#
#   web    2 workers x 3 threads (RAILS_MAX_THREADS default)      =  6
#   jobs   Solid Queue dyno (bin/jobs, config/queue.yml):
#            1 worker process x (3 job threads + 1 poller)        =  4
#            1 dispatcher + 1 scheduler (recurring.yml) + supervisor = 3
#   agents ~5 CLI/console sessions (heroku run, bin/release) x 1  =  5
#   total  18 of 20 — 2 spare for heartbeat and console blips
#
# test/lib/puma_config_contract_test.rb re-derives this budget from the parsed
# configs and fails if it reaches 20. Re-prove the math there before raising
# WEB_CONCURRENCY, RAILS_MAX_THREADS, or JOB_CONCURRENCY.
if ENV["RAILS_ENV"] == "production"
  workers Integer(ENV.fetch("WEB_CONCURRENCY", 2))
end

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
