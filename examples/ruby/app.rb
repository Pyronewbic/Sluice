require "sinatra"
set :bind, "0.0.0.0"
set :port, 4567
set :server, "puma"
get("/") { "ok from ruby\n" }
