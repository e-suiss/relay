[
  import_deps: [:ecto, :ecto_sql, :phoenix, :stream_data],
  subdirectories: ["priv/*/migrations"],
  inputs: ["*.{ex,exs}", "{config,lib,lib_dev,test,bench,credo}/**/*.{ex,exs}"]
]
