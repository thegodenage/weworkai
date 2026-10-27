# Weworkai

To start the app in Docker (Postgres included, code and browser reload on save):

* `docker compose up --build`
* Run tests with `docker compose exec -e MIX_ENV=test web mix test`
* For the Claude Code connector, run `bin/claude_bridge` on your computer (not in Docker); it lets the app use your local Claude Code login without copying credentials

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
