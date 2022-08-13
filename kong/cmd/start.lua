local migrations_utils = require "kong.cmd.utils.migrations"
local prefix_handler = require "kong.cmd.utils.prefix_handler"
local nginx_signals = require "kong.cmd.utils.nginx_signals"
local conf_loader = require "kong.conf_loader"
local kong_global = require "kong.global"
local kill = require "kong.cmd.utils.kill"
local log = require "kong.cmd.utils.log"
local DB = require "kong.db"
local lfs = require "lfs"


local function is_socket(path)
  return lfs.attributes(path, "mode") == "socket"
end

local function handle_dangling_unix_sockets(prefix, remove)
  local found

  for child in lfs.dir(prefix) do
    local path = prefix .. "/" .. child
    if is_socket(path) then
      found = found or {}
      table.insert(found, path)
    end
  end

  if not found then
    return
  end

  if remove then
    for _, sock in ipairs(found) do
      if is_socket(sock) then
        log.info("removing leftover unix socket: " .. sock)
        assert(os.remove(sock))
      end
    end
  else
    local msg = [[found dangling unix sockets in %q:
%s
Kong may fail to start. Use the --cleanup-sockets flag to remove them when starting Kong.
]]
    log.warn(msg:format(prefix, table.concat(found, "\n") .. "\n"))
  end
end

local function execute(args)
  args.db_timeout = args.db_timeout * 1000
  args.lock_timeout = args.lock_timeout

  local conf = assert(conf_loader(args.conf, {
    prefix = args.prefix
  }, { starting = true }))

  conf.pg_timeout = args.db_timeout -- connect + send + read

  conf.cassandra_timeout = args.db_timeout -- connect + send + read
  conf.cassandra_schema_consensus_timeout = args.db_timeout

  assert(prefix_handler.prepare_prefix(conf, args.nginx_conf))

  assert(not kill.is_running(conf.nginx_pid),
         "Kong is already running in " .. conf.prefix)


  handle_dangling_unix_sockets(conf.prefix, args.cleanup_sockets)

  _G.kong = kong_global.new()
  kong_global.init_pdk(_G.kong, conf)

  local db = assert(DB.new(conf))
  assert(db:init_connector())

  local schema_state = assert(db:schema_state())
  local err

  xpcall(function()
    if not schema_state:is_up_to_date() and args.run_migrations then
      migrations_utils.up(schema_state, db, {
        ttl = args.lock_timeout,
      })

      schema_state = assert(db:schema_state())
    end

    migrations_utils.check_state(schema_state)

    if schema_state.missing_migrations or schema_state.pending_migrations then
      local r = ""
      if schema_state.missing_migrations then
        log.info("Database is missing some migrations:\n%s",
                 tostring(schema_state.missing_migrations))

        r = "\n\n"
      end

      if schema_state.pending_migrations then
        log.info("%sDatabase has pending migrations:\n%s",
                 r, tostring(schema_state.pending_migrations))
      end
    end

    assert(nginx_signals.start(conf))

    log("Kong started")
  end, function(e)
    err = e -- cannot throw from this function
  end)

  if err then
    log.verbose("could not start Kong, stopping services")
    pcall(nginx_signals.stop(conf))
    log.verbose("stopped services")
    error(err) -- report to main error handler
  end
end

local lapp = [[
Usage: kong start [OPTIONS]

Start Kong (Nginx and other configured services) in the configured
prefix directory.

Options:
 -c,--conf        (optional string)   Configuration file.

 -p,--prefix      (optional string)   Override prefix directory.

 --nginx-conf     (optional string)   Custom Nginx configuration template.

 --run-migrations (optional boolean)  Run migrations before starting.

 --db-timeout     (default 60)        Timeout, in seconds, for all database
                                      operations (including schema consensus for
                                      Cassandra).

 --lock-timeout   (default 60)        When --run-migrations is enabled, timeout,
                                      in seconds, for nodes waiting on the
                                      leader node to finish running migrations.


 --cleanup-sockets (optional boolean)  Find and remove any existing unix sockets
                                       in the Kong prefix directory before starting
                                       Kong. This is useful for recovering from an
                                       unclean shutdown of Kong.
]]

return {
  lapp = lapp,
  execute = execute
}
