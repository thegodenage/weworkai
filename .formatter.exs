[
  import_deps: [:reactor, :ecto, :ecto_sql, :phoenix, :ash, :ash_postgres, :ash_phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
