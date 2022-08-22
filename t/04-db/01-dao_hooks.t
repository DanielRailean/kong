use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

master_on();
workers(8);

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: test DAO post delete hook should only be called once after concurrent deletion
--- http_config eval
qq {
    lua_shared_dict dao_test 32k;

    init_by_lua_block {
        local Schema = require("kong.db.schema.init")
        local DAO = require("kong.db.dao.init")
        local dao_test = ngx.shared.dao_test
        local hooks = require "kong.hooks"

        local strategy = {
            select = function()
                return { id = 1 }
            end,
            delete = function(pk, _)
                local counter = dao_test:incr("delete_counter", 1, 0)
                if counter == 1 then
                    return true
                end
                return nil
            end
        }
        dao = DAO.new(
            {}, 
            Schema.new({
                name = "Foo",
                primary_key = { "id" },
                fields = {
                    { id = { type = "number" }, },
                }
            }),
            strategy,
            errors
        )

        hooks.register_hook("dao:delete:post", function()
            dao_test:incr("hook_counter", 1, 0)
        end)
    }

    init_worker_by_lua_block {
        dao:delete({ id = 1 })
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local dao_test = ngx.shared.dao_test
            ngx.say(dao_test:get("hook_counter"), ",", dao_test:get("delete_counter"))
        }
    }
--- request
GET /t
--- response_body
1,8
--- no_error_log
[error]
